defmodule HTTPower.Client do
  @moduledoc """
  HTTPower client with adapter support and advanced features.

  This module provides:
  - Adapter pattern supporting multiple HTTP clients (Finch, Req, Tesla)
  - Test mode request blocking
  - Smart retry logic with exponential backoff and jitter
  - Clean error handling (never raises exceptions)
  - SSL/Proxy configuration support
  - Request timeout management

  The client sits above the adapter layer, providing consistent retry logic,
  error handling, and other production features regardless of the underlying
  HTTP client.
  """

  require Logger
  alias HTTPower.{Error, Request, Response}
  alias HTTPower.{CircuitBreaker, Dedup}

  # Compile-time config caching for performance (avoids repeated Application.get_env calls)
  # Note: test_mode MUST be runtime to allow tests to enable it dynamically
  @default_adapter Application.compile_env(:httpower, :adapter, nil)

  @default_max_retries 3
  @default_retry_safe false
  @default_base_delay 1000
  @default_max_delay 30_000
  @default_jitter_factor 0.2

  @retryable_status_codes [408, 429, 500, 502, 503, 504]

  # Feature Registry - Define all available features
  # Each entry: {module, key}
  # - module: The feature module implementing HTTPower.Feature
  # - key: Used for both Application config AND request opts (e.g., :rate_limit, :deduplicate)
  # Features are only included in the pipeline if enabled: true in config
  @available_features [
    {HTTPower.RateLimiter, :rate_limit},
    {HTTPower.CircuitBreaker, :circuit_breaker},
    {HTTPower.Dedup, :deduplicate}
  ]

  # Build request pipeline at compile-time based on enabled features
  # Inline pipeline building logic to work with module attributes
  @default_request_steps @available_features
                         |> Enum.reduce([], fn {module, key}, acc ->
                           config = Application.compile_env(:httpower, key, [])

                           # Features are enabled by default unless explicitly disabled
                           if Keyword.get(config, :enabled, true) do
                             [{module, key, config} | acc]
                           else
                             acc
                           end
                         end)
                         |> Enum.reverse()

  # Public API

  @doc """
  Makes an HTTP GET request.
  """
  @spec get(String.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def get(url, opts \\ []) do
    request(:get, url, nil, opts)
  end

  @doc """
  Makes an HTTP POST request.
  """
  @spec post(String.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def post(url, opts \\ []) do
    body = Keyword.get(opts, :body)
    request(:post, url, body, opts)
  end

  @doc """
  Makes an HTTP PUT request.
  """
  @spec put(String.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def put(url, opts \\ []) do
    body = Keyword.get(opts, :body)
    request(:put, url, body, opts)
  end

  @doc """
  Makes an HTTP DELETE request.
  """
  @spec delete(String.t(), keyword()) :: {:ok, Response.t()} | {:error, Error.t()}
  def delete(url, opts \\ []) do
    request(:delete, url, nil, opts)
  end

  # Private

  defp request(method, url, body, opts) do
    headers = Keyword.get(opts, :headers, %{})

    with {:ok, :allowed} <- check_test_mode_allows_request(opts),
         {:ok, %URI{} = uri} <- validate_url(url),
         %Request{} = request <- Request.new(method, uri, body, headers, opts),
         pipeline when is_list(pipeline) <- get_request_pipeline(opts) do
      fun = get_request_function(request, pipeline)
      execute_with_telemetry(request, fun)
    else
      {:error, %Error{}} = error ->
        error

      {:error, :network_blocked} ->
        {:error, %Error{reason: :network_blocked, message: "Network access blocked in test mode"}}

      {:error, reason} ->
        {:error, %Error{reason: reason, message: error_message(reason)}}
    end
  end

  defp validate_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error,
         %Error{
           reason: :invalid_url,
           message: "URL must use http or https scheme, got: #{inspect(uri.scheme)}"
         }}

      not is_binary(uri.host) or uri.host == "" ->
        {:error, %Error{reason: :invalid_url, message: "URL must have a valid host"}}

      true ->
        {:ok, uri}
    end
  end

  defp sanitize_uri_for_telemetry(%URI{} = uri) do
    normalized_port =
      case {uri.scheme, uri.port} do
        {"https", 443} -> nil
        {"http", 80} -> nil
        {_, port} -> port
      end

    normalized_path = uri.path || ""

    normalized_uri = %URI{
      uri
      | port: normalized_port,
        path: normalized_path,
        query: nil,
        fragment: nil
    }

    URI.to_string(normalized_uri)
  end

  defp get_request_function(%Request{} = request, pipeline) do
    fn ->
      result =
        with pipeline_result <- run_request_steps(request, pipeline),
             {:ok, final_request} <- handle_pipeline_result(pipeline_result),
             {:ok, response} <- execute_http_with_retry(final_request) do
          handle_post_request(final_request, {:ok, response})
          {:ok, response}
        else
          {:error, %Error{}} = error ->
            error

          {:error, reason} ->
            {:error, %Error{reason: reason, message: error_message(reason)}}
        end

      response_metadata =
        case result do
          {:ok, response} ->
            %{
              status: response.status,
              headers: response.headers,
              body: response.body,
              retry_count: Keyword.get(request.opts, :retry_count, 0)
            }

          {:error, %Error{reason: {:http_status, status, response}}} ->
            %{
              status: status,
              headers: response.headers,
              body: response.body,
              error_type: :http_error
            }

          {:error, %Error{reason: reason}} ->
            %{error_type: reason}

          {:error, reason} ->
            %{error_type: reason}
        end

      {result, Map.merge(request_metadata(request), response_metadata)}
    end
  end

  defp execute_with_telemetry(%Request{} = request, fun) do
    :telemetry.span([:httpower, :request], request_metadata(request), fun)
  end

  defp request_metadata(%Request{} = request) do
    %{
      method: request.method,
      url: sanitize_uri_for_telemetry(request.url),
      headers: request.headers,
      body: request.body
    }
  end

  # Get request pipeline (compile-time default + runtime custom steps)
  defp get_request_pipeline(opts) do
    custom_steps = Keyword.get(opts, :request_steps, [])
    @default_request_steps ++ custom_steps
  end

  # Handle pipeline result - unwrap short-circuits or continue
  defp handle_pipeline_result({:ok, request}), do: {:ok, request}

  # Feature short-circuited (e.g., dedup cache hit, circuit breaker open)
  defp handle_pipeline_result({:halt, response}), do: {:ok, response}

  defp handle_pipeline_result({:error, _} = error), do: error

  defp execute_http_with_retry(%Request{} = request) do
    execute_request_with_retry(
      request.method,
      request.url,
      request.body,
      request.opts
    )
  end

  defp handle_post_request(request, result) do
    case Request.get_private(request, :circuit_breaker) do
      {circuit_key, circuit_config} ->
        case result do
          {:ok, _} -> CircuitBreaker.record_success(circuit_key, circuit_config)
          {:error, _} -> CircuitBreaker.record_failure(circuit_key, circuit_config)
        end

      nil ->
        :ok
    end

    case Request.get_private(request, :dedup) do
      {dedup_hash, dedup_config} ->
        case result do
          {:ok, response} -> Dedup.complete(dedup_hash, response, dedup_config)
          {:error, _} -> Dedup.cancel(dedup_hash)
        end

      nil ->
        :ok
    end
  end

  # Pipeline Execution - Generic recursive step executor

  @doc false
  # Fast path: empty pipeline (all features disabled)
  defp run_request_steps(request, []), do: {:ok, request}

  @doc false
  # Generic step execution - works for ANY feature
  defp run_request_steps(request, [{module, option_key, compile_config} | rest]) do
    # Merge runtime config from request.opts (runtime takes precedence)
    runtime_config = extract_runtime_config(request.opts, option_key)
    merged_config = Keyword.merge(compile_config, runtime_config)

    case apply(module, :handle_request, [request, merged_config]) do
      :ok -> run_request_steps(request, rest)
      {:ok, modified_request} -> run_request_steps(modified_request, rest)
      {:halt, response} -> {:halt, response}
      {:error, _reason} = error -> error
    end
  rescue
    error ->
      {:error,
       %Error{
         reason: {:feature_error, module, error},
         message: "Feature #{module} failed: #{inspect(error)}"
       }}
  end

  # Extracts runtime configuration from request options
  # Handles: option: true → [enabled: true], option: false → [enabled: false],
  #          option: [key: value] → [key: value], nil/missing → []
  defp extract_runtime_config(opts, option_key) do
    case Keyword.get(opts, option_key) do
      nil -> []
      true -> [enabled: true]
      false -> [enabled: false]
      config when is_list(config) -> config
      _ -> []
    end
  end

  defp check_test_mode_allows_request(opts) do
    if can_do_request?(opts) do
      {:ok, :allowed}
    else
      {:error, :network_blocked}
    end
  end

  defp execute_request_with_retry(method, url, body, opts) do
    headers = Keyword.get(opts, :headers, %{})
    adapter = get_adapter(opts)

    retry_opts = %{
      max_retries: Keyword.get(opts, :max_retries, @default_max_retries),
      retry_safe: Keyword.get(opts, :retry_safe, @default_retry_safe),
      base_delay: Keyword.get(opts, :base_delay, @default_base_delay),
      max_delay: Keyword.get(opts, :max_delay, @default_max_delay),
      jitter_factor: Keyword.get(opts, :jitter_factor, @default_jitter_factor)
    }

    request_params = %{
      method: method,
      url: url,
      body: body,
      headers: headers,
      opts: opts,
      adapter: adapter
    }

    execute_http_request(request_params, retry_opts, 1)
  end

  defp execute_http_request(request_params, retry_opts, attempt) do
    %{
      adapter: adapter,
      method: method,
      url: url,
      body: body,
      headers: headers,
      opts: opts
    } = request_params

    with {:ok, response} <- call_adapter(adapter, method, url, body, headers, opts),
         {:ok, :final_response} <- check_if_response_is_retryable(response, attempt, retry_opts) do
      {:ok, response}
    else
      {:error, :should_retry, reason} ->
        handle_retry(request_params, retry_opts, attempt, reason)

      {:error, reason} when attempt < retry_opts.max_retries ->
        handle_retry(request_params, retry_opts, attempt, reason)

      {:error, reason} ->
        wrap_error(reason)
    end
  end

  # Retry Logic

  defp handle_retry(request_params, retry_opts, attempt, reason) do
    if retryable_error?(reason, retry_opts.retry_safe) do
      log_retry_attempt(attempt, reason, retry_opts.max_retries)
      delay = calculate_retry_delay(reason, attempt, retry_opts)

      :telemetry.execute(
        [:httpower, :retry, :attempt],
        %{attempt_number: attempt + 1, delay_ms: delay},
        %{
          method: request_params.method,
          url: request_params.url,
          reason: extract_retry_reason(reason)
        }
      )

      :timer.sleep(delay)
      execute_http_request(request_params, retry_opts, attempt + 1)
    else
      case reason do
        {:http_status, status, response} when status >= 200 and status < 300 ->
          {:ok, response}

        _ ->
          wrap_error(reason)
      end
    end
  end

  defp check_if_response_is_retryable(response, attempt, retry_opts) do
    if retryable_status?(response.status) and attempt < retry_opts.max_retries do
      {:error, :should_retry, {:http_status, response.status, response}}
    else
      {:ok, :final_response}
    end
  end

  defp calculate_retry_delay({:http_status, status, response}, attempt, retry_opts)
       when status in [429, 503] do
    case HTTPower.RateLimitHeaders.parse_retry_after(response.headers) do
      {:ok, seconds} ->
        Logger.info(
          "Retry-After header found: waiting #{seconds} seconds as instructed by server"
        )

        seconds * 1000

      {:error, :not_found} ->
        calculate_backoff_delay(attempt, retry_opts)
    end
  end

  defp calculate_retry_delay(_reason, attempt, retry_opts) do
    calculate_backoff_delay(attempt, retry_opts)
  end

  def calculate_backoff_delay(attempt, retry_opts) do
    factor = Integer.pow(2, attempt - 1)
    delay_before_cap = retry_opts.base_delay * factor
    max_delay = min(retry_opts.max_delay, delay_before_cap)
    jitter = 1 - retry_opts.jitter_factor * :rand.uniform()
    trunc(max_delay * jitter)
  end

  def retryable_error?({:http_status, status, _response}, _retry_safe) do
    retryable_status?(status)
  end

  def retryable_error?(%Mint.TransportError{reason: reason}, retry_safe) do
    retryable_transport_error?(reason, retry_safe)
  end

  def retryable_error?(reason, retry_safe) when is_atom(reason) do
    retryable_transport_error?(reason, retry_safe)
  end

  def retryable_error?(_, _), do: false

  def retryable_status?(status) when status in @retryable_status_codes, do: true
  def retryable_status?(_), do: false

  defp retryable_transport_error?(:timeout, _), do: true
  defp retryable_transport_error?(:closed, _), do: true
  defp retryable_transport_error?(:econnrefused, _), do: true
  defp retryable_transport_error?(:econnreset, retry_safe), do: retry_safe
  defp retryable_transport_error?(_, _), do: false

  # Adapter Management

  defp get_adapter(opts) do
    case Keyword.get(opts, :adapter) do
      nil -> get_default_adapter()
      {_adapter_module, _config} = adapter -> adapter
      adapter_module when is_atom(adapter_module) -> adapter_module
    end
  end

  defp get_default_adapter do
    case @default_adapter do
      nil -> detect_adapter()
      {_adapter_module, _config} = adapter -> adapter
      adapter_module when is_atom(adapter_module) -> adapter_module
    end
  end

  defp detect_adapter do
    cond do
      Code.ensure_loaded?(HTTPower.Adapter.Finch) ->
        HTTPower.Adapter.Finch

      Code.ensure_loaded?(HTTPower.Adapter.Req) ->
        HTTPower.Adapter.Req

      Code.ensure_loaded?(HTTPower.Adapter.Tesla) ->
        HTTPower.Adapter.Tesla

      true ->
        raise_missing_adapter_error()
    end
  end

  defp raise_missing_adapter_error do
    raise """
    HTTPower requires at least one HTTP client adapter.

    Add ONE of the following to your mix.exs dependencies:

      # Recommended for high performance (Mint-based)
      {:finch, "~> 0.20"}

      # Recommended for convenience (batteries-included)
      {:req, "~> 0.4.0"}

      # If you already use Tesla
      {:tesla, "~> 1.11"}

    Then run:
      mix deps.get

    Alternatively, specify an adapter explicitly:
      HTTPower.get(url, adapter: HTTPower.Adapter.Finch)
    """
  end

  defp call_adapter({adapter_module, config}, method, url, body, headers, opts) do
    adapter_opts = Keyword.put(opts, :adapter_config, config)
    adapter_module.request(method, url, body, headers, adapter_opts)
  end

  defp call_adapter(adapter_module, method, url, body, headers, opts)
       when is_atom(adapter_module) do
    adapter_module.request(method, url, body, headers, opts)
  end

  # Test Mode

  defp can_do_request?(opts) do
    test_mode = Application.get_env(:httpower, :test_mode, false)
    has_plug = Keyword.has_key?(opts, :plug)
    has_adapter_with_config = match?({_module, _config}, Keyword.get(opts, :adapter))
    httpower_test_enabled = HTTPower.Test.mock_enabled?()

    not test_mode or httpower_test_enabled or has_plug or has_adapter_with_config
  end

  # Retry

  defp extract_retry_reason({:http_status, status, _response}), do: {:http_status, status}
  defp extract_retry_reason(reason) when is_atom(reason), do: reason
  defp extract_retry_reason(_reason), do: :unknown

  # Logging Helpers

  defp log_retry_attempt(attempt, reason, max_retries) do
    remaining = max_retries - attempt

    Logger.info(
      "HTTPower retry attempt #{attempt} due to #{inspect(reason)}, #{remaining} attempts remaining"
    )
  end

  # Error Handling

  defp wrap_error(%Error{} = error), do: {:error, error}
  defp wrap_error(reason), do: {:error, %Error{reason: reason, message: error_message(reason)}}

  defp error_message(%Mint.TransportError{reason: reason}), do: error_message(reason)
  defp error_message({:http_status, status, _response}), do: "HTTP #{status} error"

  # Plug-compatible error atoms
  defp error_message(:too_many_requests), do: "Too many requests"
  defp error_message(:service_unavailable), do: "Service unavailable"

  # HTTPower-specific error atoms (transport/network errors)
  defp error_message(:timeout), do: "Request timeout"
  defp error_message(:econnrefused), do: "Connection refused"
  defp error_message(:econnreset), do: "Connection reset"
  defp error_message(:nxdomain), do: "Domain not found"
  defp error_message(:closed), do: "Connection closed"
  defp error_message(:dedup_timeout), do: "Request deduplication timeout"

  defp error_message(reason), do: inspect(reason)
end

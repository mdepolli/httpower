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

  alias HTTPower.{Error, Request, Response}
  alias HTTPower.Middleware.{CircuitBreaker, Dedup}

  # Compile-time config caching for performance (avoids repeated Application.get_env calls)
  # Note: test_mode MUST be runtime to allow tests to enable it dynamically
  @default_adapter Application.compile_env(:httpower, :adapter, nil)

  # Middleware Registry - Define all available middleware
  # Each entry: {module, key}
  # - module: The middleware module implementing HTTPower.Middleware
  # - key: Used for both Application config AND request opts (e.g., :rate_limit, :deduplicate)
  # Middleware are only included in the pipeline if enabled: true in config
  #
  # IMPORTANT: Order matters for coordination!
  # - Dedup runs FIRST so cache hits bypass rate limiting (5x effective capacity)
  # - RateLimiter runs before circuit breaker (rate limit failures shouldn't open circuit)
  # - CircuitBreaker runs last to protect the actual HTTP call
  @available_features [
    {HTTPower.Middleware.Dedup, :deduplicate},
    {HTTPower.Middleware.RateLimiter, :rate_limit},
    {HTTPower.Middleware.CircuitBreaker, :circuit_breaker}
  ]

  # Build request pipeline at compile-time based on enabled middleware
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
        {:error, %Error{reason: reason, message: Error.message(reason)}}
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
        case run_request_steps(request, pipeline) do
          {:ok, %Request{} = final_request} ->
            result = execute_http_with_retry(final_request)
            handle_post_request(final_request, result)
            result

          {:halt, %Response{} = response} ->
            # Pipeline short-circuited (e.g., dedup cache hit, circuit breaker open)
            # Response already finalized, no HTTP call needed
            {:ok, response}

          {:error, %Error{}} = error ->
            error

          {:error, reason} ->
            {:error, %Error{reason: reason, message: Error.message(reason)}}
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

  defp execute_http_with_retry(%Request{} = request) do
    headers = Keyword.get(request.opts, :headers, %{})
    adapter = get_adapter(request.opts)

    HTTPower.Retry.execute_with_retry(
      request.method,
      request.url,
      request.body,
      headers,
      adapter,
      request.opts
    )
  end

  defp handle_post_request(request, result) do
    if cb = Request.get_private(request, :circuit_breaker) do
      {circuit_key, circuit_config} = cb

      case result do
        {:ok, _} -> CircuitBreaker.record_success(circuit_key, circuit_config)
        {:error, _} -> CircuitBreaker.record_failure(circuit_key, circuit_config)
      end
    end

    if dedup = Request.get_private(request, :dedup) do
      {dedup_hash, dedup_config} = dedup

      case result do
        {:ok, response} -> Dedup.complete(dedup_hash, response, dedup_config)
        {:error, _} -> Dedup.cancel(dedup_hash)
      end
    end
  end

  # Pipeline Execution - Generic recursive step executor

  defp run_request_steps(request, []), do: {:ok, request}

  defp run_request_steps(request, [{module, option_key, compile_config} | rest]) do
    # Merge runtime config from request.opts (runtime takes precedence)
    runtime_config = extract_runtime_config(request.opts, option_key)
    merged_config = Keyword.merge(compile_config, runtime_config)

    case module.handle_request(request, merged_config) do
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
         message: "Middleware #{module} failed: #{inspect(error)}"
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

  @doc false
  def call_adapter({adapter_module, config}, method, url, body, headers, opts) do
    adapter_opts = Keyword.put(opts, :adapter_config, config)
    adapter_module.request(method, url, body, headers, adapter_opts)
  end

  @doc false
  def call_adapter(adapter_module, method, url, body, headers, opts)
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
end

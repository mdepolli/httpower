defmodule HTTPower.Client do
  @moduledoc """
  HTTPower client with adapter support and advanced features.

  This module provides:
  - Adapter pattern supporting multiple HTTP clients (Req, Tesla)
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
  alias HTTPower.{Response, Error}
  alias HTTPower.Logger, as: HTTPowerLogger
  alias HTTPower.{RateLimiter, CircuitBreaker, Dedup}

  @default_max_retries 3
  @default_retry_safe false
  @default_base_delay 1000
  @default_max_delay 30_000
  @default_jitter_factor 0.2

  @retryable_status_codes [408, 429, 500, 502, 503, 504]

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

  # Main Request Pipeline

  defp request(method, url, body, opts) do
    with {:ok, :allowed} <- check_test_mode_allows_request(opts),
         {:ok, :rate_limit_passed} <- check_rate_limit(url, opts),
         {:ok, dedup_action} <- check_deduplication(method, url, body, opts),
         {:ok, response} <- execute_with_dedup(dedup_action, url, opts, method, body) do
      {:ok, response}
    else
      {:error, :network_blocked} ->
        {:error, %Error{reason: :network_blocked, message: "Network access blocked in test mode"}}

      {:error, %Error{}} = error ->
        error

      {:error, reason} ->
        {:error, %Error{reason: reason, message: error_message(reason)}}
    end
  end

  defp check_test_mode_allows_request(opts) do
    if can_do_request?(opts) do
      {:ok, :allowed}
    else
      {:error, :network_blocked}
    end
  end

  defp check_rate_limit(url, opts) do
    rate_limit_key = get_rate_limit_key(url, opts)
    rate_limit_config = get_rate_limit_config(opts)

    case RateLimiter.consume(rate_limit_key, rate_limit_config) do
      :ok -> {:ok, :rate_limit_passed}
      {:error, _reason} = error -> error
    end
  end

  defp check_deduplication(method, url, body, opts) do
    dedup_config = get_deduplication_config(opts)
    dedup_hash = get_deduplication_hash(method, url, body, opts)

    case Dedup.deduplicate(dedup_hash, dedup_config) do
      {:ok, :execute} ->
        {:ok, {:execute, dedup_hash, dedup_config}}

      {:ok, :wait, ref} ->
        {:ok, {:wait, ref}}

      {:ok, response} ->
        {:ok, {:cached, response}}

      {:error, _} = error ->
        error
    end
  end

  defp execute_with_dedup({:execute, dedup_hash, dedup_config}, url, opts, method, body) do
    result =
      execute_with_circuit_breaker(url, opts, fn ->
        execute_request_with_retry(method, url, body, opts)
      end)

    case result do
      {:ok, response} ->
        Dedup.complete(dedup_hash, response, dedup_config)
        {:ok, response}

      {:error, _} = error ->
        Dedup.cancel(dedup_hash)
        error
    end
  end

  defp execute_with_dedup({:wait, ref}, _url, _opts, _method, _body) do
    receive do
      {:dedup_response, ^ref, response} -> {:ok, response}
    after
      30_000 -> {:error, :dedup_timeout}
    end
  end

  defp execute_with_dedup({:cached, response}, _url, _opts, _method, _body) do
    {:ok, response}
  end

  defp execute_with_circuit_breaker(url, opts, request_fn) do
    circuit_breaker_key = get_circuit_breaker_key(url, opts)
    circuit_breaker_config = get_circuit_breaker_config(opts)

    case CircuitBreaker.call(circuit_breaker_key, request_fn, circuit_breaker_config) do
      {:ok, _} = success -> success
      {:error, _} = error -> error
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

    correlation_id = HTTPowerLogger.log_request(method, url, headers: headers, body: body)
    start_time = System.monotonic_time(:millisecond)

    request_params = %{
      method: method,
      url: url,
      body: body,
      headers: headers,
      opts: opts,
      adapter: adapter,
      correlation_id: correlation_id,
      start_time: start_time
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
      opts: opts,
      correlation_id: correlation_id,
      start_time: start_time
    } = request_params

    with {:ok, response} <- call_adapter(adapter, method, url, body, headers, opts),
         {:ok, :final_response} <- check_if_response_is_retryable(response, attempt, retry_opts) do
      log_success_response(correlation_id, response, start_time)
      {:ok, response}
    else
      {:error, :should_retry, reason} ->
        handle_retry(request_params, retry_opts, attempt, reason)

      {:error, reason} when attempt < retry_opts.max_retries ->
        handle_retry(request_params, retry_opts, attempt, reason)

      {:error, reason} ->
        log_final_error(correlation_id, reason)
        wrap_error(reason)
    end
  end

  # Retry Logic

  defp handle_retry(request_params, retry_opts, attempt, reason) do
    if retryable_error?(reason, retry_opts.retry_safe) do
      log_retry_attempt(attempt, reason, retry_opts.max_retries)
      delay = calculate_retry_delay(reason, attempt, retry_opts)
      :timer.sleep(delay)
      execute_http_request(request_params, retry_opts, attempt + 1)
    else
      case reason do
        {:http_status, status, response} when status >= 200 and status < 300 ->
          correlation_id = request_params.correlation_id
          start_time = request_params.start_time
          duration_ms = System.monotonic_time(:millisecond) - start_time

          HTTPowerLogger.log_response(correlation_id, status,
            headers: response.headers,
            body: response.body,
            duration_ms: duration_ms
          )

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
    case Application.get_env(:httpower, :adapter) do
      nil -> detect_adapter()
      {_adapter_module, _config} = adapter -> adapter
      adapter_module when is_atom(adapter_module) -> adapter_module
    end
  end

  defp detect_adapter do
    cond do
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

    Add one of the following to your mix.exs dependencies:

      # Recommended for new projects (batteries-included)
      {:req, "~> 0.4.0"}

      # If you already use Tesla
      {:tesla, "~> 1.11"}

    Then run:
      mix deps.get

    Alternatively, specify an adapter explicitly:
      HTTPower.get(url, adapter: HTTPower.Adapter.Req)
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

  # Rate Limit Configuration

  defp get_rate_limit_key(url, opts) do
    case Keyword.get(opts, :rate_limit_key) do
      nil ->
        uri = URI.parse(url)
        uri.host || url

      custom_key ->
        custom_key
    end
  end

  defp get_rate_limit_config(opts) do
    rate_limit_opts = Keyword.get(opts, :rate_limit, [])

    case rate_limit_opts do
      opts when is_list(opts) -> opts
      false -> [enabled: false]
      true -> []
      _ -> []
    end
  end

  # Circuit Breaker Configuration

  defp get_circuit_breaker_key(url, opts) do
    case Keyword.get(opts, :circuit_breaker_key) do
      nil ->
        uri = URI.parse(url)
        uri.host || url

      custom_key ->
        custom_key
    end
  end

  defp get_circuit_breaker_config(opts) do
    circuit_breaker_opts = Keyword.get(opts, :circuit_breaker, [])

    case circuit_breaker_opts do
      opts when is_list(opts) -> opts
      false -> [enabled: false]
      true -> []
      _ -> []
    end
  end

  # Request Deduplication Configuration

  defp get_deduplication_hash(method, url, body, opts) do
    case Keyword.get(opts, :deduplicate) do
      config when is_list(config) ->
        case Keyword.get(config, :key) do
          nil -> Dedup.hash(method, url, body)
          custom_key -> custom_key
        end

      _ ->
        Dedup.hash(method, url, body)
    end
  end

  defp get_deduplication_config(opts) do
    dedup_opts = Keyword.get(opts, :deduplicate, [])

    case dedup_opts do
      opts when is_list(opts) -> opts
      true -> []
      false -> [enabled: false]
      _ -> [enabled: false]
    end
  end

  # Logging Helpers

  defp log_success_response(correlation_id, response, start_time) do
    duration_ms = System.monotonic_time(:millisecond) - start_time

    HTTPowerLogger.log_response(correlation_id, response.status,
      headers: response.headers,
      body: response.body,
      duration_ms: duration_ms
    )
  end

  defp log_final_error(correlation_id, reason) do
    case wrap_error(reason) do
      {:error, %Error{} = err} ->
        HTTPowerLogger.log_error(correlation_id, err.reason, err.message)

      _ ->
        :ok
    end
  end

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
  defp error_message(:timeout), do: "Request timeout"
  defp error_message(:econnrefused), do: "Connection refused"
  defp error_message(:econnreset), do: "Connection reset"
  defp error_message(:nxdomain), do: "Domain not found"
  defp error_message(:closed), do: "Connection closed"
  defp error_message(:rate_limit_exceeded), do: "Rate limit exceeded"
  defp error_message(:rate_limit_wait_timeout), do: "Rate limit wait timeout"
  defp error_message(:circuit_breaker_open), do: "Circuit breaker is open"
  defp error_message(:dedup_timeout), do: "Request deduplication timeout"
  defp error_message(reason), do: inspect(reason)
end

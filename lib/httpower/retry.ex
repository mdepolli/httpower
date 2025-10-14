defmodule HTTPower.Retry do
  @moduledoc """
  Retry logic with exponential backoff and jitter for HTTP requests.

  Provides resilient HTTP execution by automatically retrying failed requests
  with intelligent backoff strategies. Retry is an execution wrapper that sits
  between the middleware pipeline and the HTTP adapter layer.

  ## How It Works

  1. **Request Execution** - Calls the HTTP adapter
  2. **Response Analysis** - Checks if the response/error is retryable
  3. **Retry Decision** - Decides whether to retry based on:
     - HTTP status codes (408, 429, 500, 502, 503, 504)
     - Transport errors (timeout, closed, econnrefused, econnreset if safe)
     - Remaining retry attempts
  4. **Backoff Calculation** - Calculates delay using exponential backoff with jitter
  5. **Retry Execution** - Waits and retries the request

  ## Configuration

      # Global defaults (can be overridden per-request)
      HTTPower.get(url,
        max_retries: 3,         # Maximum retry attempts (default: 3)
        retry_safe: false,      # Retry on connection reset (default: false)
        base_delay: 1000,       # Base delay in ms (default: 1000)
        max_delay: 30_000,      # Maximum delay cap in ms (default: 30000)
        jitter_factor: 0.2      # Jitter randomization 0.0-1.0 (default: 0.2)
      )

  ## Retry-After Header Support

  For 429 (Too Many Requests) and 503 (Service Unavailable) responses,
  HTTPower automatically respects the `Retry-After` header if present:

      # Server sends: Retry-After: 5
      # HTTPower waits exactly 5 seconds instead of exponential backoff
      {:ok, response} = HTTPower.get(url)

  ## Retryable Errors

  **HTTP Status Codes:**
  - 408 Request Timeout
  - 429 Too Many Requests
  - 500 Internal Server Error
  - 502 Bad Gateway
  - 503 Service Unavailable
  - 504 Gateway Timeout

  **Transport Errors:**
  - `:timeout` - Request timeout
  - `:closed` - Connection closed
  - `:econnrefused` - Connection refused
  - `:econnreset` - Connection reset (only if `retry_safe: true`)

  ## Exponential Backoff Formula

      delay = min(max_delay, base_delay * 2^(attempt-1)) * (1 - jitter * random())

  Example delays (base_delay: 1000, jitter_factor: 0.2):
  - Attempt 1: 800-1000ms
  - Attempt 2: 1600-2000ms
  - Attempt 3: 3200-4000ms

  ## Examples

      # Retry with custom configuration
      HTTPower.get("https://flaky-api.com",
        max_retries: 5,
        base_delay: 2000,
        max_delay: 60_000
      )

      # Enable retry on connection reset
      HTTPower.get("https://api.example.com",
        retry_safe: true
      )

      # Check if error is retryable
      HTTPower.Retry.retryable_status?(500)  # true
      HTTPower.Retry.retryable_status?(404)  # false

  ## Architecture Note

  Retry is NOT implemented as middleware because:
  - Middleware run BEFORE HTTP execution (request processing)
  - Retry runs DURING HTTP execution (execution wrapper)
  - Middleware run once, retry may execute multiple times
  - This separation ensures middleware coordination works correctly:
    - Circuit breaker evaluates once per logical request (not per retry attempt)
    - Rate limiter consumes token once (retries don't consume extra tokens)
    - Dedup treats retries as same logical request
  """

  require Logger
  alias HTTPower.Error

  # Default retry configuration
  @default_max_retries 3
  @default_retry_safe false
  @default_base_delay 1000
  @default_max_delay 30_000
  @default_jitter_factor 0.2

  # Retryable HTTP status codes (industry standard)
  @retryable_status_codes [408, 429, 500, 502, 503, 504]

  @doc """
  Executes an HTTP request with retry logic.

  This is the main entry point called by `HTTPower.Client`. It wraps the
  HTTP adapter call with retry logic and exponential backoff.

  ## Parameters

  - `method` - HTTP method (:get, :post, :put, :delete)
  - `url` - Request URL (URI struct or string)
  - `body` - Request body (string or nil)
  - `headers` - Request headers (map)
  - `adapter` - HTTP adapter module or {module, config} tuple
  - `opts` - Request options (includes retry configuration)

  ## Returns

  - `{:ok, HTTPower.Response.t()}` on success
  - `{:error, HTTPower.Error.t()}` on failure (after exhausting retries)

  ## Examples

      HTTPower.Retry.execute_with_retry(
        :get,
        URI.parse("https://api.example.com"),
        nil,
        %{},
        HTTPower.Adapter.Finch,
        [max_retries: 3]
      )
  """
  def execute_with_retry(method, url, body, headers, adapter, opts) do
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

  @doc """
  Checks if an HTTP status code is retryable.

  ## Examples

      iex> HTTPower.Retry.retryable_status?(500)
      true

      iex> HTTPower.Retry.retryable_status?(404)
      false
  """
  def retryable_status?(status) when status in @retryable_status_codes, do: true
  def retryable_status?(_), do: false

  @doc """
  Checks if an error reason is retryable.

  Takes into account the `retry_safe` configuration for connection reset errors.

  ## Parameters

  - `reason` - Error reason (HTTP status tuple, transport error, or atom)
  - `retry_safe` - Whether to retry on connection reset (boolean)

  ## Examples

      iex> HTTPower.Retry.retryable_error?({:http_status, 500, response}, false)
      true

      iex> HTTPower.Retry.retryable_error?(:timeout, false)
      true

      iex> HTTPower.Retry.retryable_error?(:econnreset, false)
      false

      iex> HTTPower.Retry.retryable_error?(:econnreset, true)
      true
  """
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

  @doc """
  Calculates exponential backoff delay with jitter.

  The delay increases exponentially with each attempt, capped at `max_delay`,
  and randomized with jitter to prevent thundering herd.

  ## Parameters

  - `attempt` - Current attempt number (1-based)
  - `retry_opts` - Map with :base_delay, :max_delay, :jitter_factor

  ## Formula

      delay = min(max_delay, base_delay * 2^(attempt-1)) * (1 - jitter_factor * random())

  ## Examples

      iex> opts = %{base_delay: 1000, max_delay: 30_000, jitter_factor: 0.2}
      iex> HTTPower.Retry.calculate_backoff_delay(1, opts)
      800..1000  # Range due to jitter

      iex> HTTPower.Retry.calculate_backoff_delay(2, opts)
      1600..2000

      iex> HTTPower.Retry.calculate_backoff_delay(3, opts)
      3200..4000
  """
  def calculate_backoff_delay(attempt, retry_opts) do
    factor = Integer.pow(2, attempt - 1)
    delay_before_cap = retry_opts.base_delay * factor
    max_delay = min(retry_opts.max_delay, delay_before_cap)
    jitter = 1 - retry_opts.jitter_factor * :rand.uniform()
    trunc(max_delay * jitter)
  end

  # Private Functions

  defp execute_http_request(request_params, retry_opts, attempt) do
    %{
      adapter: adapter,
      method: method,
      url: url,
      body: body,
      headers: headers,
      opts: opts
    } = request_params

    with {:ok, response} <-
           HTTPower.Client.call_adapter(adapter, method, url, body, headers, opts),
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

  # Calculates retry delay, respecting Retry-After header for 429/503 responses
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

  defp retryable_transport_error?(:timeout, _), do: true
  defp retryable_transport_error?(:closed, _), do: true
  defp retryable_transport_error?(:econnrefused, _), do: true
  defp retryable_transport_error?(:econnreset, retry_safe), do: retry_safe
  defp retryable_transport_error?(_, _), do: false

  defp extract_retry_reason({:http_status, status, _response}), do: {:http_status, status}
  defp extract_retry_reason(reason) when is_atom(reason), do: reason
  defp extract_retry_reason(_reason), do: :unknown

  defp log_retry_attempt(attempt, reason, max_retries) do
    remaining = max_retries - attempt

    Logger.info(
      "HTTPower retry attempt #{attempt} due to #{inspect(reason)}, #{remaining} attempts remaining"
    )
  end

  defp wrap_error(%Error{} = error), do: {:error, error}
  defp wrap_error(reason), do: {:error, %Error{reason: reason, message: error_message(reason)}}

  defp error_message(%Mint.TransportError{reason: reason}), do: error_message(reason)
  defp error_message({:http_status, status, _response}), do: "HTTP #{status} error"
  defp error_message(:timeout), do: "Request timeout"
  defp error_message(:econnrefused), do: "Connection refused"
  defp error_message(:econnreset), do: "Connection reset"
  defp error_message(:nxdomain), do: "Domain not found"
  defp error_message(:closed), do: "Connection closed"
  defp error_message(reason), do: inspect(reason)
end

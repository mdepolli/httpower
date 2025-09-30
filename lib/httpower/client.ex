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

  @default_max_retries 3
  # 1 second base delay
  @default_base_delay 1000
  # 30 seconds max delay
  @default_max_delay 30_000
  # 20% jitter
  @default_jitter_factor 0.2

  # 408: Request Timeout, 429: Too Many Requests, 500-504: Server errors
  @retryable_status_codes [408, 429, 500, 502, 503, 504]

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

  # Private implementation

  defp request(method, url, body, opts) do
    # Extract HTTPower-specific options
    headers = Keyword.get(opts, :headers, %{})
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    retry_safe = Keyword.get(opts, :retry_safe, false)
    base_delay = Keyword.get(opts, :base_delay, @default_base_delay)
    max_delay = Keyword.get(opts, :max_delay, @default_max_delay)
    jitter_factor = Keyword.get(opts, :jitter_factor, @default_jitter_factor)

    # Get adapter (default to Req)
    adapter = get_adapter(opts)

    # Build retry options
    retry_opts = %{
      max_retries: max_retries,
      retry_safe: retry_safe,
      base_delay: base_delay,
      max_delay: max_delay,
      jitter_factor: jitter_factor
    }

    # Build request parameters for adapter
    request_params = %{
      method: method,
      url: url,
      body: body,
      headers: headers,
      opts: opts,
      adapter: adapter
    }

    # Execute with retry logic
    do_request(request_params, retry_opts, 1)
  end

  defp get_adapter(opts) do
    case Keyword.get(opts, :adapter) do
      nil -> get_default_adapter()
      {_adapter_module, _config} = adapter -> adapter
      adapter_module when is_atom(adapter_module) -> adapter_module
    end
  end

  defp get_default_adapter do
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

  defp do_request(request_params, retry_opts, attempt) do
    %{method: method, url: url, body: body, headers: headers, opts: opts, adapter: adapter} =
      request_params

    with true <- can_do_request?(opts),
         {:ok, response} <- call_adapter(adapter, method, url, body, headers, opts),
         false <- retryable_status?(response.status) and attempt < retry_opts.max_retries do
      {:ok, response}
    else
      false ->
        {:error, %Error{reason: :network_blocked, message: "Network access blocked in test mode"}}

      true ->
        # Response has retryable status and we have retries left
        {:ok, response} = call_adapter(adapter, method, url, body, headers, opts)
        handle_retry(request_params, retry_opts, attempt, {:http_status, response.status})

      {:error, reason} when attempt < retry_opts.max_retries ->
        handle_retry(request_params, retry_opts, attempt, reason)

      {:error, reason} ->
        wrap_error(reason)
    end
  end

  defp can_do_request?(opts) do
    test_mode = Application.get_env(:httpower, :test_mode, false)
    has_plug = Keyword.has_key?(opts, :plug)
    has_adapter_with_config = match?({_module, _config}, Keyword.get(opts, :adapter))
    httpower_test_enabled = HTTPower.Test.mock_enabled?()

    # Allow request if:
    # 1. Test mode is disabled, OR
    # 2. HTTPower.Test mocking is enabled (adapter-agnostic mocking), OR
    # 3. Adapter-specific mocking is configured (plug or adapter config)
    not test_mode or httpower_test_enabled or has_plug or has_adapter_with_config
  end

  defp call_adapter({adapter_module, config}, method, url, body, headers, opts) do
    # Adapter with configuration (e.g., {HTTPower.Adapter.Tesla, tesla_client})
    adapter_opts = Keyword.put(opts, :adapter_config, config)
    adapter_module.request(method, url, body, headers, adapter_opts)
  end

  defp call_adapter(adapter_module, method, url, body, headers, opts)
       when is_atom(adapter_module) do
    # Simple adapter module
    adapter_module.request(method, url, body, headers, opts)
  end

  defp handle_retry(request_params, retry_opts, attempt, reason) do
    if retryable_error?(reason, retry_opts.retry_safe) do
      log_retry_attempt(attempt, reason, retry_opts.max_retries)

      # Apply exponential backoff with jitter
      delay = calculate_backoff_delay(attempt, retry_opts)
      :timer.sleep(delay)

      do_request(request_params, retry_opts, attempt + 1)
    else
      wrap_error(reason)
    end
  end

  defp wrap_error(%Error{} = error), do: {:error, error}
  defp wrap_error(reason), do: {:error, %Error{reason: reason, message: error_message(reason)}}

  def calculate_backoff_delay(attempt, retry_opts) do
    # Exponential backoff: 2^attempt
    factor = Integer.pow(2, attempt - 1)
    delay_before_cap = retry_opts.base_delay * factor

    # Apply maximum delay cap
    max_delay = min(retry_opts.max_delay, delay_before_cap)

    # Apply jitter to prevent thundering herd
    # Generates jitter between (1 - jitter_factor) and 1
    jitter = 1 - retry_opts.jitter_factor * :rand.uniform()

    # Calculate final delay with jitter
    trunc(max_delay * jitter)
  end

  defp log_retry_attempt(attempt, reason, max_retries) do
    remaining = max_retries - attempt

    Logger.info(
      "HTTPower retry attempt #{attempt} due to #{inspect(reason)}, #{remaining} attempts remaining"
    )
  end

  def retryable_error?({:http_status, status}, _retry_safe) do
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

  defp error_message(%Mint.TransportError{reason: reason}), do: error_message(reason)
  defp error_message({:http_status, status}), do: "HTTP #{status} error"
  defp error_message(:timeout), do: "Request timeout"
  defp error_message(:econnrefused), do: "Connection refused"
  defp error_message(:econnreset), do: "Connection reset"
  defp error_message(:nxdomain), do: "Domain not found"
  defp error_message(:closed), do: "Connection closed"
  defp error_message(reason), do: inspect(reason)
end

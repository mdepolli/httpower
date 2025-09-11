defmodule HTTPower.Client do
  @moduledoc """
  HTTPower client that wraps Req with advanced features.

  This module provides:
  - Test mode request blocking with Req.Test integration
  - Smart retry logic with configurable policies
  - Clean error handling (never raises exceptions)
  - SSL/Proxy configuration support
  - Request timeout management
  """

  require Logger
  alias HTTPower.{Response, Error}

  @default_timeout 60
  @default_max_retries 3

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
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ssl_verify = Keyword.get(opts, :ssl_verify, true)
    proxy = Keyword.get(opts, :proxy, :system)

    # Build Req options
    req_opts = build_req_opts(method, url, body, headers, timeout, ssl_verify, proxy, opts)

    # Execute with retry logic
    do_request(req_opts, max_retries, retry_safe, 1)
  end

  defp build_req_opts(method, url, body, headers, timeout, ssl_verify, proxy, opts) do
    base_opts = [
      method: method,
      url: url,
      headers: prepare_headers(headers, method),
      receive_timeout: timeout * 1000
    ]

    # Extract any additional options (like :plug for Req.Test)
    additional_opts =
      Keyword.drop(opts, [
        :headers,
        :max_retries,
        :retry_safe,
        :timeout,
        :ssl_verify,
        :proxy,
        :body
      ])

    base_opts
    |> maybe_add_body(body)
    |> maybe_add_ssl_options(url, ssl_verify)
    |> maybe_add_proxy_options(proxy)
    |> Keyword.merge(additional_opts)
  end

  defp maybe_add_body(opts, nil), do: opts
  defp maybe_add_body(opts, body), do: Keyword.put(opts, :body, body)

  defp maybe_add_ssl_options(opts, url, ssl_verify) do
    if String.contains?(url, "https://") do
      ssl_opts = [verify: if(ssl_verify, do: :verify_peer, else: :verify_none)]
      Keyword.put(opts, :connect_options, transport_opts: ssl_opts)
    else
      opts
    end
  end

  defp maybe_add_proxy_options(opts, :system),
    do: Keyword.put(opts, :connect_options, proxy: :system)

  defp maybe_add_proxy_options(opts, nil), do: opts

  defp maybe_add_proxy_options(opts, proxy_opts) when is_list(proxy_opts) do
    Keyword.put(opts, :connect_options, proxy: proxy_opts)
  end

  defp maybe_add_proxy_options(opts, _), do: opts

  defp prepare_headers(headers, :post) do
    default_post_headers = %{"Content-Type" => "application/x-www-form-urlencoded"}

    Map.merge(default_post_headers, headers)
    |> Map.put("connection", "close")
  end

  defp prepare_headers(headers, _method) do
    Map.put(headers, "connection", "close")
  end

  defp do_request(req_opts, max_retries, retry_safe, attempt) do
    with true <- can_do_request?(req_opts),
         {:ok, response} <- safe_req_request(req_opts) do
      # Check if HTTP status code should be retried
      if retryable_status?(response.status) and attempt < max_retries do
        handle_retry(req_opts, max_retries, retry_safe, attempt, {:http_status, response.status})
      else
        {:ok, convert_response(response)}
      end
    else
      false ->
        {:error, %Error{reason: :network_blocked, message: "Network access blocked in test mode"}}

      {:error, reason} when attempt < max_retries ->
        handle_retry(req_opts, max_retries, retry_safe, attempt, reason)

      {:error, reason} ->
        {:error, %Error{reason: reason, message: error_message(reason)}}
    end
  end

  defp can_do_request?(req_opts) do
    test_mode = Application.get_env(:httpower, :test_mode, false)
    has_plug = Keyword.has_key?(req_opts, :plug)

    not test_mode or has_plug
  end

  defp safe_req_request(req_opts) do
    try do
      case Req.request(req_opts) do
        {:ok, response} -> {:ok, response}
        {:error, reason} -> {:error, reason}
      end
    rescue
      error -> {:error, error}
    catch
      error -> {:error, error}
    end
  end

  defp convert_response(%Req.Response{status: status, headers: headers, body: body}) do
    %Response{
      status: status,
      headers: Map.new(headers),
      body: body
    }
  end

  defp handle_retry(req_opts, max_retries, retry_safe, attempt, reason) do
    if retryable_error?(reason, retry_safe) do
      log_retry_attempt(attempt, reason, max_retries)
      do_request(req_opts, max_retries, retry_safe, attempt + 1)
    else
      {:error, %Error{reason: reason, message: error_message(reason)}}
    end
  end

  defp log_retry_attempt(attempt, reason, max_retries) do
    remaining = max_retries - attempt

    Logger.info(
      "HTTPower retry attempt #{attempt} due to #{inspect(reason)}, #{remaining} attempts remaining"
    )
  end

  defp retryable_error?({:http_status, status}, _retry_safe) do
    retryable_status?(status)
  end

  defp retryable_error?(%Mint.TransportError{reason: reason}, retry_safe) do
    retryable_transport_error?(reason, retry_safe)
  end

  defp retryable_error?(reason, retry_safe) when is_atom(reason) do
    retryable_transport_error?(reason, retry_safe)
  end

  defp retryable_error?(_, _), do: false

  defp retryable_status?(status) when status in @retryable_status_codes, do: true
  defp retryable_status?(_), do: false

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

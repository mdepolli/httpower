if Code.ensure_loaded?(Req) do
  defmodule HTTPower.Adapter.Req do
    @moduledoc """
      Req adapter for HTTPower.

    This adapter uses the Req HTTP client library to make HTTP requests. Req is a
    "batteries-included" HTTP client with features like automatic body encoding/decoding,
    compression, and more.

    ## Features

    - Automatic JSON encoding/decoding
    - Response body decompression (gzip, brotli, zstd)
    - SSL/TLS support with configurable verification
    - Proxy support (system or custom)
    - Integration with `Req.Test` for testing

    ## Configuration

    The Req adapter accepts standard HTTPower options plus any Req-specific options:

    - `timeout` - Request timeout in seconds (converted to milliseconds for Req)
    - `ssl_verify` - Enable SSL verification (default: true)
    - `proxy` - Proxy configuration (`:system`, `nil`, or custom options)
    - `plug` - Req.Test plug for testing (e.g., `{Req.Test, MyApp}`)

    ## Testing

    The Req adapter works seamlessly with `Req.Test` for mocking HTTP requests in tests:

        # In your test
        Req.Test.stub(MyApp, fn conn ->
          Req.Test.json(conn, %{status: "success"})
        end)

        HTTPower.get("https://api.example.com",
          adapter: HTTPower.Adapter.Req,
          plug: {Req.Test, MyApp})

    ## Important

    This adapter **disables Req's built-in retry logic** by setting `retry: false`.
    HTTPower's own retry logic (with exponential backoff and jitter) is used instead,
    ensuring consistent retry behavior across all adapters.
    """

    @behaviour HTTPower.Adapter

    alias HTTPower.Response

    @impl true
    def request(method, url, body, headers, opts) do
      case HTTPower.TestInterceptor.intercept(method, url, body, headers) do
        {:intercepted, result} -> result
        :continue -> do_request(method, url, body, headers, opts)
      end
    end

    defp do_request(method, url, body, headers, opts) do
      timeout = Keyword.get(opts, :timeout, 60)
      ssl_verify = Keyword.get(opts, :ssl_verify, true)
      proxy = Keyword.get(opts, :proxy, :system)

      req_opts = build_req_opts(method, url, body, headers, timeout, ssl_verify, proxy, opts)

      with {:ok, response} <- safe_req_request(req_opts) do
        {:ok, convert_response(response)}
      end
    end

    defp build_req_opts(method, url, body, headers, timeout, ssl_verify, proxy, opts) do
      base_opts = [
        method: method,
        url: url,
        headers: prepare_headers(headers, method),
        receive_timeout: timeout * 1000,
        # IMPORTANT: Disable Req's built-in retry to avoid conflicts with HTTPower's retry logic
        retry: false
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
          :body,
          :base_delay,
          :max_delay,
          :jitter_factor,
          :adapter
        ])

      base_opts
      |> maybe_add_body(body)
      |> maybe_add_ssl_options(url, ssl_verify)
      |> maybe_add_proxy_options(proxy)
      |> Keyword.merge(additional_opts)
    end

    defp maybe_add_body(opts, nil), do: opts
    defp maybe_add_body(opts, body), do: Keyword.put(opts, :body, body)

    defp maybe_add_ssl_options(opts, %URI{scheme: "https"}, ssl_verify) do
      ssl_opts = [verify: if(ssl_verify, do: :verify_peer, else: :verify_none)]
      existing = Keyword.get(opts, :connect_options, [])
      updated = Keyword.put(existing, :transport_opts, ssl_opts)
      Keyword.put(opts, :connect_options, updated)
    end

    defp maybe_add_ssl_options(opts, _url, _ssl_verify), do: opts

    defp maybe_add_proxy_options(opts, :system) do
      existing = Keyword.get(opts, :connect_options, [])
      updated = Keyword.put(existing, :proxy, :system)
      Keyword.put(opts, :connect_options, updated)
    end

    defp maybe_add_proxy_options(opts, nil), do: opts

    defp maybe_add_proxy_options(opts, proxy_opts) when is_list(proxy_opts) do
      existing = Keyword.get(opts, :connect_options, [])
      updated = Keyword.put(existing, :proxy, proxy_opts)
      Keyword.put(opts, :connect_options, updated)
    end

    defp maybe_add_proxy_options(opts, _), do: opts

    defp prepare_headers(headers, :post) do
      default_post_headers = %{"Content-Type" => "application/x-www-form-urlencoded"}
      Map.merge(default_post_headers, headers)
    end

    defp prepare_headers(headers, _method) do
      headers
    end

    defp safe_req_request(req_opts) do
      Req.request(req_opts)
    rescue
      error -> {:error, unwrap_transport_error(error)}
    catch
      error -> {:error, error}
    end

    defp unwrap_transport_error(%{__struct__: Mint.TransportError, reason: reason}), do: reason
    defp unwrap_transport_error(error), do: error

    defp convert_response(%Req.Response{status: status, headers: headers, body: body}) do
      %Response{
        status: status,
        headers: Map.new(headers),
        body: body
      }
    end
  end
end

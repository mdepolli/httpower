if Code.ensure_loaded?(Finch) do
  defmodule HTTPower.Adapter.Finch do
    @moduledoc """
      Finch adapter for HTTPower.

    This adapter uses the Finch HTTP client library to make HTTP requests. Finch is a
    performance-focused HTTP client built on Mint and NimblePool, with explicit connection
    pooling and excellent performance characteristics.

    ## Features

    - High-performance HTTP/1.1 and HTTP/2 support
    - Explicit connection pooling with configurable pool sizes
    - Built on Mint for low-level HTTP transport
    - SSL/TLS support with configurable verification
    - Proxy support (system or custom)
    - Manual JSON decoding for flexibility

    ## Configuration

    The Finch adapter accepts standard HTTPower options:

    - `timeout` - Request timeout in seconds (converted to milliseconds for Finch)
    - `ssl_verify` - Enable SSL verification (default: true)
    - `proxy` - Proxy configuration (`:system`, `nil`, or custom options)

    ## Pool Configuration

    Configure Finch pools globally in your application config:

        config :httpower, :finch_pools,
          default: [
            size: 10,
            count: System.schedulers_online(),
            conn_opts: [
              timeout: 5_000
            ]
          ]

    ## Testing

    The Finch adapter works seamlessly with `HTTPower.Test` for mocking HTTP requests in tests.
    The test interceptor runs before Finch is called, providing adapter-agnostic testing.

    ## Performance

    Finch is recommended for high-throughput production scenarios where explicit connection
    pooling control and maximum performance are priorities. It's built on Mint, the same
    low-level library that powers Req.
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

      finch_opts = build_finch_opts(url, timeout, ssl_verify, proxy)

      with {:ok, response} <- safe_finch_request(method, url, body, headers, finch_opts) do
        {:ok, convert_response(response)}
      end
    end

    defp build_finch_opts(url, timeout, ssl_verify, proxy) do
      base_opts = [
        receive_timeout: timeout * 1000
      ]

      base_opts
      |> maybe_add_ssl_options(url, ssl_verify)
      |> maybe_add_proxy_options(proxy)
    end

    defp maybe_add_ssl_options(opts, url, ssl_verify) do
      uri = if is_binary(url), do: URI.parse(url), else: url

      case uri do
        %URI{scheme: "https"} ->
          ssl_opts = [verify: if(ssl_verify, do: :verify_peer, else: :verify_none)]
          conn_opts = Keyword.get(opts, :conn_opts, [])
          transport_opts = Keyword.get(conn_opts, :transport_opts, [])

          updated_transport_opts = Keyword.merge(transport_opts, ssl_opts)
          updated_conn_opts = Keyword.put(conn_opts, :transport_opts, updated_transport_opts)

          Keyword.put(opts, :conn_opts, updated_conn_opts)

        _ ->
          opts
      end
    end

    defp maybe_add_proxy_options(opts, :system) do
      conn_opts = Keyword.get(opts, :conn_opts, [])
      updated_conn_opts = Keyword.put(conn_opts, :proxy, :system)
      Keyword.put(opts, :conn_opts, updated_conn_opts)
    end

    defp maybe_add_proxy_options(opts, nil), do: opts

    defp maybe_add_proxy_options(opts, proxy_opts) when is_list(proxy_opts) do
      conn_opts = Keyword.get(opts, :conn_opts, [])
      updated_conn_opts = Keyword.put(conn_opts, :proxy, proxy_opts)
      Keyword.put(opts, :conn_opts, updated_conn_opts)
    end

    defp maybe_add_proxy_options(opts, _), do: opts

    defp safe_finch_request(method, url, body, headers, opts) do
      prepared_headers = prepare_headers(headers, method)
      # Convert URI struct to string if needed
      url_string = if is_binary(url), do: url, else: URI.to_string(url)
      request = Finch.build(method, url_string, format_headers(prepared_headers), body || "")

      Finch.request(request, HTTPower.Finch, opts)
    rescue
      error -> {:error, unwrap_transport_error(error)}
    catch
      error -> {:error, error}
    end

    defp unwrap_transport_error(%{__struct__: Mint.TransportError, reason: reason}), do: reason
    defp unwrap_transport_error(error), do: error

    defp prepare_headers(headers, :post) do
      default_post_headers = %{"Content-Type" => "application/x-www-form-urlencoded"}
      Map.merge(default_post_headers, headers)
    end

    defp prepare_headers(headers, _method) do
      headers
    end

    defp format_headers(headers) when is_map(headers) do
      Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
    end

    defp convert_response(%Finch.Response{status: status, headers: headers, body: body}) do
      %Response{
        status: status,
        headers: convert_headers(headers),
        body: parse_body(body)
      }
    end

    defp convert_headers(headers) when is_list(headers) do
      # Finch returns headers as list of tuples: [{"key", "value"}]
      # We need to convert to: %{"key" => ["value"]} to match Req format
      Enum.reduce(headers, %{}, fn {key, value}, acc ->
        Map.update(acc, key, [value], fn existing -> [value | existing] end)
      end)
      |> Enum.map(fn {key, values} -> {key, Enum.reverse(values)} end)
      |> Map.new()
    end

    defp parse_body(body) when is_binary(body) do
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        {:error, _} -> body
      end
    end

    defp parse_body(body), do: body
  end
end

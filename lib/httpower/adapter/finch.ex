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
    - Pool-level SSL/TLS and proxy configuration

    ## Configuration

    The Finch adapter honors these per-request options:

    - `timeout` - Receive timeout in seconds (converted to milliseconds for Finch)
    - `pool_timeout` - Max time in milliseconds to wait to check out a pooled
      connection (defaults to Finch's own default of 5000 when not set)

    > #### Per-request `ssl_verify` and `proxy` are not supported {: .warning}
    >
    > Finch configures TLS verification and proxy at the **pool** level (baked in
    > at `Finch.start_link`), not per request — `Finch.request/3` has no
    > connection options. Passing `ssl_verify:` or `proxy:` per request has no
    > effect with this adapter; configure them on the pool instead (below).
    > Without explicit TLS config the pool inherits Mint's default
    > `verify: :verify_peer`, so certificates are verified by default. The Req
    > and Tesla adapters honor these options differently — see their docs.

    ## Pool Configuration

    Configure Finch pools — including TLS and proxy — globally in your
    application config (these flow straight into Finch's `:pools`):

        config :httpower, :finch_pools,
          default: [
            size: 10,
            count: System.schedulers_online(),
            conn_opts: [
              transport_opts: [verify: :verify_peer],
              proxy: {:http, "proxy.example.com", 8080, []}
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
      finch_opts = build_finch_opts(opts)

      with {:ok, response} <- safe_finch_request(method, url, body, headers, finch_opts) do
        {:ok, convert_response(response)}
      end
    end

    # Only per-request options Finch actually honors are set here. TLS
    # verification and proxy are pool-level config in Finch (consumed at
    # Finch.start_link, not per request), so they are configured via
    # `config :httpower, :finch_pools` — see the moduledoc.
    defp build_finch_opts(opts) do
      timeout = Keyword.get(opts, :timeout, 60)
      base_opts = [receive_timeout: timeout * 1000]

      case Keyword.get(opts, :pool_timeout) do
        nil -> base_opts
        pool_timeout -> Keyword.put(base_opts, :pool_timeout, pool_timeout)
      end
    end

    defp safe_finch_request(method, url, body, headers, opts) do
      prepared_headers = prepare_headers(headers)
      # Pass nil through as "no body"; Finch.build accepts nil. Coercing to ""
      # would emit Content-Length: 0 on bodyless requests (e.g. GET).
      request = Finch.build(method, url, format_headers(prepared_headers), body)

      case Finch.request(request, HTTPower.Finch, opts) do
        {:ok, response} -> {:ok, response}
        {:error, reason} -> {:error, unwrap_transport_error(reason)}
      end
    rescue
      error -> {:error, unwrap_transport_error(error)}
    catch
      error -> {:error, error}
    end

    defp unwrap_transport_error(%{__struct__: Mint.TransportError, reason: reason}), do: reason
    defp unwrap_transport_error(error), do: error

    defp prepare_headers(headers), do: HTTPower.Adapter.prepare_headers(headers)

    defp format_headers(headers) when is_map(headers) do
      Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
    end

    defp convert_response(%Finch.Response{status: status, headers: headers, body: body}) do
      %Response{
        status: status,
        headers: convert_headers(headers),
        body: body
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
  end
end

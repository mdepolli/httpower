if Code.ensure_loaded?(Tesla) do
  defmodule HTTPower.Adapter.Tesla do
    @moduledoc """
    Tesla adapter for HTTPower.

    This adapter allows HTTPower to work with existing Tesla clients, enabling you
    to add HTTPower's production features (circuit breakers, rate limiting, retry
    logic, PCI logging) on top of your existing Tesla setup without rewriting your
    HTTP infrastructure.

    ## Features

    - Works with any Tesla client configuration
    - Preserves Tesla middleware stack
    - Supports all Tesla adapters (Finch, Hackney, Mint, Gun, etc.)
    - Transparent pass-through of Tesla features

    ## Configuration

    The Tesla adapter requires a Tesla client to be passed in the options:

        # Create your Tesla client
        tesla_client = Tesla.client([
          Tesla.Middleware.BaseUrl.new("https://api.example.com"),
          Tesla.Middleware.JSON,
          Tesla.Middleware.Logger
        ])

        # Use with HTTPower
        client = HTTPower.new(
          adapter: {HTTPower.Adapter.Tesla, tesla_client}
        )

        HTTPower.get(client, "/users")

    ## Testing

    For testing, you can use Tesla's testing capabilities:

        # Use Tesla.Mock for testing
        Tesla.Mock.mock(fn
          %{method: :get, url: "https://api.example.com/users"} ->
            %Tesla.Env{status: 200, body: %{"users" => []}}
        end)

    Or use HTTPower's test mode blocking:

        Application.put_env(:httpower, :test_mode, true)
        # Requests will be blocked unless using a test adapter

    ## Tesla Client Middleware

    The Tesla adapter respects all middleware in your Tesla client:

    - Authentication middleware (Bearer, Basic, OAuth)
    - Retry middleware (note: disable if using HTTPower's retry)
    - Logging middleware
    - Custom middleware

    ## Important: JSON Middleware

    If your Tesla client includes `Tesla.Middleware.JSON`, you should remove it
    when wrapping with HTTPower. HTTPower handles JSON encoding/decoding via
    `HTTPower.Codec`, and having both active will cause double-decoding:

        # Before (double-decoding risk)
        Tesla.client([Tesla.Middleware.JSON])

        # After (correct)
        Tesla.client([])  # HTTPower handles JSON via json: option

    ## Connection options are configured on the Tesla client, not per request

    Unlike the Finch and Req adapters, this adapter does **not** forward the
    `timeout`, `ssl_verify`, or `proxy` request options to Tesla — Tesla
    configures those on the client itself (e.g. `Tesla.Middleware.Timeout` and
    the chosen Tesla adapter's transport/proxy options). Passing them to
    `HTTPower.get/2` etc. with this adapter has no effect; configure them when
    you build the Tesla client instead.

    ## Example

        # Define Tesla client with middleware
        defmodule MyApp.ApiClient do
          use Tesla

          plug Tesla.Middleware.BaseUrl, "https://api.example.com"
          plug Tesla.Middleware.JSON
          plug Tesla.Middleware.Headers, [{"authorization", "Bearer token"}]

          # Use Finch adapter
          adapter Tesla.Adapter.Finch, name: MyApp.Finch
        end

        # Wrap with HTTPower for production features
        tesla_client = MyApp.ApiClient.client()

        client = HTTPower.new(
          adapter: {HTTPower.Adapter.Tesla, tesla_client},
          circuit_breaker: [threshold: 5],  # Future feature
          rate_limit: [requests: 100, per: :second]  # Future feature
        )

        # Make requests - Tesla handles HTTP, HTTPower adds reliability
        {:ok, response} = HTTPower.get(client, "/users")
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
      with {:ok, tesla_client} <- get_tesla_client(opts),
           tesla_opts = build_tesla_opts(method, url, body, headers),
           {:ok, env} <- safe_tesla_request(tesla_client, tesla_opts) do
        {:ok, convert_response(env)}
      end
    end

    defp get_tesla_client(opts) do
      case Keyword.get(opts, :adapter_config) do
        nil ->
          {:error,
           %HTTPower.Error{
             reason: :missing_tesla_client,
             message: HTTPower.Error.message(:missing_tesla_client)
           }}

        tesla_client ->
          {:ok, tesla_client}
      end
    end

    defp build_tesla_opts(method, url, body, headers) do
      [
        method: method,
        url: url_to_string(url),
        # Pass nil through as "no body"; Tesla.Env.body defaults to nil. Coercing
        # to "" would emit Content-Length: 0 on bodyless requests (e.g. GET).
        body: body,
        headers: convert_headers(headers)
      ]
    end

    defp url_to_string(%URI{} = uri), do: URI.to_string(uri)
    defp url_to_string(url) when is_binary(url), do: url

    # Convert HTTPower headers (map) to Tesla headers (list of tuples)
    defp convert_headers(headers) when is_map(headers) do
      Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
    end

    defp convert_headers(headers) when is_list(headers), do: headers
    defp convert_headers(_), do: []

    defp safe_tesla_request(client, opts) do
      case Tesla.request(client, opts) do
        {:ok, env} -> {:ok, env}
        {:error, reason} -> {:error, unwrap_transport_error(reason)}
      end
    rescue
      error -> {:error, unwrap_transport_error(error)}
    catch
      error -> {:error, error}
    end

    # Mirror the Finch/Req adapters: extract the bare reason atom from a
    # Mint.TransportError so HTTPower.Retry can classify it as a retryable
    # transport error. Matched structurally to avoid a compile-time
    # dependency on Mint (an optional, adapter-specific dependency).
    defp unwrap_transport_error(%{__struct__: Mint.TransportError, reason: reason}), do: reason
    defp unwrap_transport_error(error), do: error

    defp convert_response(%Tesla.Env{} = env) do
      %Response{
        status: env.status,
        headers: convert_response_headers(env.headers),
        body: env.body
      }
    end

    # Convert Tesla response headers to normalized map with list values.
    # Matches the Finch adapter format: %{"key" => ["val1", "val2"]}
    # This correctly handles HTTP headers that may have multiple values
    # (e.g., Set-Cookie) by grouping them into lists.
    defp convert_response_headers(headers) when is_list(headers) do
      # Prepend + reverse to preserve original order (same approach as Finch adapter)
      Enum.reduce(headers, %{}, fn {k, v}, acc ->
        key = to_string(k)
        Map.update(acc, key, [v], fn existing -> [v | existing] end)
      end)
      |> Enum.map(fn {key, values} -> {key, Enum.reverse(values)} end)
      |> Map.new()
    end

    defp convert_response_headers(headers) when is_map(headers) do
      Map.new(headers, fn
        {k, v} when is_list(v) -> {k, v}
        {k, v} -> {k, [v]}
      end)
    end

    defp convert_response_headers(_), do: %{}
  end
end

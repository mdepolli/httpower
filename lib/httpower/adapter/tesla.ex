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
    - JSON encoding/decoding
    - Custom middleware

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
      tesla_client = get_tesla_client(opts)

      # Build Tesla request options
      tesla_opts = build_tesla_opts(method, url, body, headers)

      with {:ok, env} <- safe_tesla_request(tesla_client, tesla_opts) do
        {:ok, convert_response(env)}
      end
    end

    defp get_tesla_client(opts) do
      case Keyword.get(opts, :adapter_config) do
        nil ->
          raise ArgumentError,
                "Tesla adapter requires a Tesla client. " <>
                  "Use: HTTPower.get(url, adapter: {HTTPower.Adapter.Tesla, tesla_client})"

        tesla_client ->
          tesla_client
      end
    end

    defp build_tesla_opts(method, url, body, headers) do
      [
        method: method,
        url: url,
        body: body || "",
        headers: convert_headers(headers)
      ]
    end

    # Convert HTTPower headers (map) to Tesla headers (list of tuples)
    defp convert_headers(headers) when is_map(headers) do
      Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
    end

    defp convert_headers(headers) when is_list(headers), do: headers
    defp convert_headers(_), do: []

    defp safe_tesla_request(client, opts) do
      try do
        Tesla.request(client, opts)
      rescue
        error -> {:error, error}
      catch
        error -> {:error, error}
      end
    end

    defp convert_response(%Tesla.Env{} = env) do
      %Response{
        status: env.status,
        headers: convert_response_headers(env.headers),
        body: env.body
      }
    end

    # Convert Tesla response headers (list of tuples) to map
    defp convert_response_headers(headers) when is_list(headers) do
      Map.new(headers, fn {k, v} -> {to_string(k), v} end)
    end

    defp convert_response_headers(headers) when is_map(headers), do: headers
    defp convert_response_headers(_), do: %{}
  end
end

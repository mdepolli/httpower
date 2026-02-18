defmodule HTTPower.Adapter do
  @moduledoc """
  Behaviour for HTTPower adapters.

  Adapters are responsible for making the actual HTTP requests using a specific
  HTTP client library (Req, Tesla, etc.). HTTPower's features like retry logic,
  circuit breakers, and rate limiting sit above the adapter layer.

  ## Implementing an Adapter

  To implement an adapter, create a module that implements the `c:request/5` callback:

      defmodule MyApp.CustomAdapter do
        @behaviour HTTPower.Adapter

        @impl true
        def request(method, url, body, headers, opts) do
          # Make HTTP request using your preferred HTTP client
          # Convert response to {:ok, %HTTPower.Response{}} or {:error, reason}
        end
      end

  ## Built-in Adapters

  HTTPower ships with three built-in adapters:

  - `HTTPower.Adapter.Finch` - Uses Finch HTTP client, built on Mint + NimblePool (default)
  - `HTTPower.Adapter.Req` - Uses Req HTTP client (batteries-included)
  - `HTTPower.Adapter.Tesla` - Uses Tesla HTTP client (bring-your-own-config)

  ## Using an Adapter

  Specify the adapter when making requests:

      # Use default (Finch) adapter
      HTTPower.get("https://api.example.com")

      # Use explicit Req adapter
      HTTPower.get("https://api.example.com", adapter: HTTPower.Adapter.Req)

      # Use Tesla adapter with your Tesla client
      tesla_client = Tesla.client([Tesla.Middleware.JSON])
      HTTPower.get("https://api.example.com",
        adapter: {HTTPower.Adapter.Tesla, tesla_client})

  ## Adapter Contract

  Adapters must return responses in a standardized format:

  - Success: `{:ok, %HTTPower.Response{status: integer(), headers: map(), body: term()}}`
  - Failure: `{:error, reason}` where reason can be an atom, string, or exception

  HTTPower's retry logic and error handling work consistently across all adapters.
  """

  alias HTTPower.Response

  @doc """
  Makes an HTTP request using the adapter's underlying HTTP client.

  ## Parameters

  - `method` - HTTP method as an atom (`:get`, `:post`, `:put`, `:delete`)
  - `url` - Full URL as a string
  - `body` - Request body (string, map, or nil)
  - `headers` - Map of request headers
  - `opts` - Keyword list of adapter-specific options

  ## Returns

  - `{:ok, %HTTPower.Response{}}` on successful request
  - `{:error, reason}` on failure

  ## Examples

      @impl true
      def request(:get, "https://api.example.com/users", nil, %{}, _opts) do
        {:ok, %HTTPower.Response{
          status: 200,
          headers: %{"content-type" => "application/json"},
          body: %{"users" => []}
        }}
      end
  """
  @callback request(
              method :: atom(),
              url :: String.t(),
              body :: term(),
              headers :: map(),
              opts :: keyword()
            ) :: {:ok, Response.t()} | {:error, term()}
end

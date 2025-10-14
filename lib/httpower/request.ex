defmodule HTTPower.Request do
  @moduledoc """
  Internal request representation for the HTTPower pipeline.

  This struct wraps request data and provides a context for features to
  communicate and store data as requests flow through the pipeline.

  ## Fields

  - `method` - HTTP method (`:get`, `:post`, `:put`, `:delete`)
  - `url` - Request URL (string)
  - `body` - Request body (string, map, or nil)
  - `headers` - Request headers (map)
  - `opts` - Request options (keyword list)
  - `private` - Private storage for feature communication (map)

  ## The `private` Field

  The `private` field is a map that features can use to:
  - Store data for post-request processing
  - Pass data between features
  - Cache expensive computations

  Example:

      # Feature stores data in private
      def handle_request(request, _config) do
        private = Map.put(request.private, :circuit_breaker, {key, config})
        {:ok, %{request | private: private}}
      end

      # Later, post-request handler reads it
      circuit_info = Map.get(request.private, :circuit_breaker)

  ## Usage

  This struct is internal to HTTPower and created automatically. Users
  typically don't need to create Request structs directly.

  However, when implementing custom features, you'll receive and return
  Request structs in your `handle_request/2` callback:

      defmodule MyFeature do
        @behaviour HTTPower.Middleware

        def handle_request(request, _config) do
          # Modify the request
          updated_request = %{request | headers: new_headers}
          {:ok, updated_request}
        end
      end
  """

  @type t :: %__MODULE__{
          method: :get | :post | :put | :delete | :patch | :head | :options,
          url: URI.t(),
          body: term(),
          headers: map(),
          opts: keyword(),
          private: map()
        }

  @enforce_keys [:method, :url]
  defstruct [
    :method,
    :url,
    body: nil,
    headers: %{},
    opts: [],
    private: %{}
  ]

  @doc """
  Creates a new Request struct.

  The URL must be a validated URI struct (not a string). This ensures
  URL validation happens early in the request pipeline.

  ## Examples

      iex> uri = URI.parse("https://api.example.com")
      iex> HTTPower.Request.new(:get, uri)
      %HTTPower.Request{
        method: :get,
        url: %URI{scheme: "https", host: "api.example.com", ...},
        body: nil,
        headers: %{},
        opts: [],
        private: %{}
      }

      iex> uri = URI.parse("https://api.example.com")
      iex> HTTPower.Request.new(:post, uri, "data", %{"content-type" => "text/plain"})
      %HTTPower.Request{
        method: :post,
        url: %URI{scheme: "https", host: "api.example.com", ...},
        body: "data",
        headers: %{"content-type" => "text/plain"}
      }
  """
  @spec new(atom(), URI.t(), term(), map(), keyword()) :: t()
  def new(method, %URI{} = url, body \\ nil, headers \\ %{}, opts \\ []) do
    %__MODULE__{
      method: method,
      url: url,
      body: body,
      headers: headers,
      opts: opts,
      private: %{}
    }
  end

  @doc """
  Stores a value in the request's private storage.

  ## Examples

      iex> request = HTTPower.Request.new(:get, "https://example.com")
      iex> request = HTTPower.Request.put_private(request, :my_key, "my_value")
      iex> request.private
      %{my_key: "my_value"}
  """
  @spec put_private(t(), atom(), term()) :: t()
  def put_private(%__MODULE__{} = request, key, value) when is_atom(key) do
    private = Map.put(request.private, key, value)
    %{request | private: private}
  end

  @doc """
  Retrieves a value from the request's private storage.

  Returns `nil` if the key doesn't exist, or the provided default value.

  ## Examples

      iex> request = HTTPower.Request.new(:get, "https://example.com")
      iex> request = HTTPower.Request.put_private(request, :my_key, "my_value")
      iex> HTTPower.Request.get_private(request, :my_key)
      "my_value"

      iex> request = HTTPower.Request.new(:get, "https://example.com")
      iex> HTTPower.Request.get_private(request, :missing_key)
      nil

      iex> request = HTTPower.Request.new(:get, "https://example.com")
      iex> HTTPower.Request.get_private(request, :missing_key, "default")
      "default"
  """
  @spec get_private(t(), atom(), term()) :: term()
  def get_private(%__MODULE__{} = request, key, default \\ nil) when is_atom(key) do
    Map.get(request.private, key, default)
  end

  @doc """
  Updates the request headers by merging with existing headers.

  Request-level headers take precedence over existing headers.

  ## Examples

      iex> request = HTTPower.Request.new(:get, "https://example.com", nil, %{"accept" => "application/json"})
      iex> request = HTTPower.Request.merge_headers(request, %{"authorization" => "Bearer token"})
      iex> request.headers
      %{"accept" => "application/json", "authorization" => "Bearer token"}

      iex> request = HTTPower.Request.new(:get, "https://example.com", nil, %{"accept" => "application/json"})
      iex> request = HTTPower.Request.merge_headers(request, %{"accept" => "application/xml"})
      iex> request.headers
      %{"accept" => "application/xml"}
  """
  @spec merge_headers(t(), map()) :: t()
  def merge_headers(%__MODULE__{} = request, new_headers) when is_map(new_headers) do
    headers = Map.merge(request.headers, new_headers)
    %{request | headers: headers}
  end

  @doc """
  Updates a specific header value.

  ## Examples

      iex> request = HTTPower.Request.new(:get, "https://example.com")
      iex> request = HTTPower.Request.put_header(request, "authorization", "Bearer token")
      iex> request.headers
      %{"authorization" => "Bearer token"}
  """
  @spec put_header(t(), String.t(), String.t()) :: t()
  def put_header(%__MODULE__{} = request, key, value) when is_binary(key) and is_binary(value) do
    headers = Map.put(request.headers, key, value)
    %{request | headers: headers}
  end

  @doc """
  Retrieves a header value.

  Returns `nil` if the header doesn't exist, or the provided default value.

  ## Examples

      iex> request = HTTPower.Request.new(:get, "https://example.com", nil, %{"accept" => "application/json"})
      iex> HTTPower.Request.get_header(request, "accept")
      "application/json"

      iex> request = HTTPower.Request.new(:get, "https://example.com")
      iex> HTTPower.Request.get_header(request, "missing")
      nil

      iex> request = HTTPower.Request.new(:get, "https://example.com")
      iex> HTTPower.Request.get_header(request, "missing", "default")
      "default"
  """
  @spec get_header(t(), String.t(), String.t() | nil) :: String.t() | nil
  def get_header(%__MODULE__{} = request, key, default \\ nil) when is_binary(key) do
    Map.get(request.headers, key, default)
  end
end

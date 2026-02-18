defmodule HTTPower do
  @moduledoc """
  A production-ready HTTP client library for Elixir that adds reliability patterns
  and enterprise features on top of existing HTTP clients through an adapter system.

  HTTPower supports multiple HTTP clients via adapters — Finch (high-performance, default),
  Req (batteries-included), and Tesla (bring-your-own-config) — while providing production
  reliability features that work consistently across all of them:

  - **Adapter pattern**: Choose between Finch, Req, or Tesla HTTP clients
  - **Middleware pipeline**: Rate limiting, circuit breaker, and request deduplication
  - **Smart retries**: Exponential backoff with jitter and Retry-After header support
  - **PCI-compliant logging**: Automatic sanitization of sensitive data with structured metadata
  - **Telemetry integration**: Comprehensive observability for all operations
  - **Configuration profiles**: Pre-built profiles for payment processing, high-volume APIs, and microservices
  - **Clean error handling**: Never raises exceptions, always returns `{:ok, response}` or `{:error, reason}`
  - **Test utilities**: Adapter-agnostic test helpers via `HTTPower.Test`

  ## Basic Usage

      # Simple GET request
      HTTPower.get("https://api.example.com/users")

      # POST with data
      HTTPower.post("https://api.example.com/users",
        body: "name=John&email=john@example.com",
        headers: %{"Content-Type" => "application/x-www-form-urlencoded"}
      )

      # With configuration options
      HTTPower.get("https://api.example.com/slow-endpoint",
        timeout: 30,
        max_retries: 5,
        retry_safe: true
      )

  ## Test Mode

  HTTPower can block real HTTP requests during testing while allowing mocked requests:

      # In test configuration
      Application.put_env(:httpower, :test_mode, true)

      # This will be blocked
      HTTPower.get("https://real-api.com")  # {:error, %HTTPower.Error{reason: :network_blocked}}

      # But this will work with Req.Test
      HTTPower.get("https://api.com", plug: {Req.Test, MyApp})

  ## Configuration Options

  - `timeout` - Request timeout in seconds (default: 60)
  - `max_retries` - Maximum retry attempts (default: 3)
  - `retry_safe` - Enable retries for connection resets (default: false)
  - `ssl_verify` - Enable SSL verification (default: true)
  - `proxy` - Proxy configuration (default: :system)
  - `headers` - Request headers map

  ## Return Values

  All HTTP methods return either:
  - `{:ok, %HTTPower.Response{}}` on success
  - `{:error, %HTTPower.Error{}}` on failure

  HTTPower never raises exceptions for network errors, ensuring your application
  stays stable even when external services fail.

  ## Configured Clients

  You can create pre-configured client instances for reuse:

      # Create a configured client
      client = HTTPower.new(
        base_url: "https://api.example.com",
        headers: %{"Authorization" => "Bearer token"},
        timeout: 30,
        max_retries: 5
      )

      # Use the client for multiple requests
      HTTPower.get(client, "/users")
      HTTPower.post(client, "/users", body: %{name: "John"})

  This is especially useful for API clients, different environments, or service-specific configuration.
  """

  alias HTTPower.Client

  @type client :: %__MODULE__{
          base_url: String.t() | nil,
          options: keyword()
        }

  defstruct base_url: nil, options: []

  @doc """
  Creates a new HTTPower client with pre-configured options.

  ## Options

  - `base_url` - Base URL to prepend to all requests
  - `profile` - Pre-configured profile (`:payment_processing`, `:high_volume_api`, `:microservices_mesh`)
  - All other options are the same as individual request options (see module documentation)

  When using a profile, profile settings are merged with explicit options.
  Explicit options always take precedence over profile defaults.

  ## Examples

      # Simple client with base URL
      client = HTTPower.new(base_url: "https://api.example.com")

      # Client with authentication and timeouts
      client = HTTPower.new(
        base_url: "https://api.example.com",
        headers: %{"Authorization" => "Bearer token"},
        timeout: 30,
        max_retries: 5,
        retry_safe: true
      )

      # Use a profile for optimal settings
      client = HTTPower.new(
        base_url: "https://payment-gateway.com",
        profile: :payment_processing
      )

      # Profile with overrides
      client = HTTPower.new(
        base_url: "https://api.example.com",
        profile: :high_volume_api,
        rate_limit: [requests: 2000]  # Override profile's rate limit
      )

  """
  @spec new(keyword()) :: client()
  def new(opts \\ []) do
    # Extract profile and base_url
    {profile, opts} = Keyword.pop(opts, :profile)
    {base_url, opts} = Keyword.pop(opts, :base_url)

    # Merge profile settings with user options (user options win)
    options =
      case profile do
        nil ->
          opts

        profile_name ->
          case HTTPower.Profiles.get(profile_name) do
            {:ok, profile_config} ->
              deep_merge_options(profile_config, opts)

            {:error, :unknown_profile} ->
              raise ArgumentError, """
              Unknown profile: #{inspect(profile_name)}

              Available profiles: #{inspect(HTTPower.Profiles.list())}
              """
          end
      end

    %__MODULE__{base_url: base_url, options: options}
  end

  @doc """
  Makes an HTTP GET request.

  Accepts either a URL string or a configured client as the first argument.

  ## Options

  See module documentation for available options.

  ## Examples

      # With URL string
      HTTPower.get("https://api.example.com/users")
      HTTPower.get("https://api.example.com/users", headers: %{"Authorization" => "Bearer token"})

      # With configured client
      client = HTTPower.new(base_url: "https://api.example.com")
      HTTPower.get(client, "/users")

  """
  # Function header with default value
  def get(url_or_client, opts_or_path \\ [])

  # URL + options pattern
  @spec get(String.t(), keyword()) :: {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def get(url, opts) when is_binary(url) do
    Client.get(url, opts)
  end

  # Client + path pattern (calls 3-arity with empty options)
  @spec get(client(), String.t()) :: {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def get(%__MODULE__{} = client, path) when is_binary(path) do
    get(client, path, [])
  end

  # Client + path + options pattern (3-arity)
  @spec get(client(), String.t(), keyword()) ::
          {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def get(%__MODULE__{} = client, path, opts) when is_binary(path) and is_list(opts) do
    {url, merged_opts} = prepare_client_request(client, path, opts)
    Client.get(url, merged_opts)
  end

  @doc """
  Makes an HTTP POST request.

  Accepts either a URL string or a configured client as the first argument.

  ## Options

  See module documentation for available options. Additionally supports:
  - `body` - Request body (string or form data)

  ## Examples

      # With URL string
      HTTPower.post("https://api.example.com/users", body: "name=John")
      HTTPower.post("https://api.example.com/users",
        body: Jason.encode!(%{name: "John"}),
        headers: %{"Content-Type" => "application/json"}
      )

      # With configured client
      client = HTTPower.new(base_url: "https://api.example.com")
      HTTPower.post(client, "/users", body: %{name: "John"})

  """
  # Function header with default value
  def post(url_or_client, opts_or_path \\ [])

  # URL + options pattern
  @spec post(String.t(), keyword()) :: {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def post(url, opts) when is_binary(url) do
    Client.post(url, opts)
  end

  # Client + path pattern (calls 3-arity with empty options)
  @spec post(client(), String.t()) :: {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def post(%__MODULE__{} = client, path) when is_binary(path) do
    post(client, path, [])
  end

  # Client + path + options pattern (3-arity)
  @spec post(client(), String.t(), keyword()) ::
          {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def post(%__MODULE__{} = client, path, opts) when is_binary(path) and is_list(opts) do
    {url, merged_opts} = prepare_client_request(client, path, opts)
    Client.post(url, merged_opts)
  end

  @doc """
  Makes an HTTP PUT request.

  Accepts either a URL string or a configured client as the first argument.

  ## Options

  See module documentation for available options. Additionally supports:
  - `body` - Request body (string or form data)

  ## Examples

      # With URL string
      HTTPower.put("https://api.example.com/users/1", body: "name=John")

      # With configured client
      client = HTTPower.new(base_url: "https://api.example.com")
      HTTPower.put(client, "/users/1", body: %{name: "John"})

  """
  # Function header with default value
  def put(url_or_client, opts_or_path \\ [])

  # URL + options pattern
  @spec put(String.t(), keyword()) :: {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def put(url, opts) when is_binary(url) do
    Client.put(url, opts)
  end

  # Client + path pattern (calls 3-arity with empty options)
  @spec put(client(), String.t()) :: {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def put(%__MODULE__{} = client, path) when is_binary(path) do
    put(client, path, [])
  end

  # Client + path + options pattern (3-arity)
  @spec put(client(), String.t(), keyword()) ::
          {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def put(%__MODULE__{} = client, path, opts) when is_binary(path) and is_list(opts) do
    {url, merged_opts} = prepare_client_request(client, path, opts)
    Client.put(url, merged_opts)
  end

  @doc """
  Makes an HTTP DELETE request.

  Accepts either a URL string or a configured client as the first argument.

  ## Options

  See module documentation for available options.

  ## Examples

      # With URL string
      HTTPower.delete("https://api.example.com/users/1")

      # With configured client
      client = HTTPower.new(base_url: "https://api.example.com")
      HTTPower.delete(client, "/users/1")

  """
  # Function header with default value
  def delete(url_or_client, opts_or_path \\ [])

  # URL + options pattern
  @spec delete(String.t(), keyword()) ::
          {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def delete(url, opts) when is_binary(url) do
    Client.delete(url, opts)
  end

  # Client + path pattern (calls 3-arity with empty options)
  @spec delete(client(), String.t()) ::
          {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def delete(%__MODULE__{} = client, path) when is_binary(path) do
    delete(client, path, [])
  end

  # Client + path + options pattern (3-arity)
  @spec delete(client(), String.t(), keyword()) ::
          {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def delete(%__MODULE__{} = client, path, opts) when is_binary(path) and is_list(opts) do
    {url, merged_opts} = prepare_client_request(client, path, opts)
    Client.delete(url, merged_opts)
  end

  # Private helper function to prepare client requests
  defp prepare_client_request(
         %__MODULE__{base_url: base_url, options: client_opts},
         path,
         request_opts
       ) do
    url = build_url(base_url, path)
    merged_opts = merge_client_options(client_opts, request_opts)
    {url, merged_opts}
  end

  defp build_url(nil, path), do: path
  defp build_url(base_url, ""), do: base_url
  defp build_url(base_url, "/" <> _ = path), do: base_url <> path
  defp build_url(base_url, path), do: base_url <> "/" <> path

  defp merge_client_options(client_opts, request_opts) do
    # Merge headers specially - combine rather than replace
    client_headers = Keyword.get(client_opts, :headers, %{})
    request_headers = Keyword.get(request_opts, :headers, %{})
    merged_headers = Map.merge(client_headers, request_headers)

    # Merge all options, with request options taking precedence
    client_opts
    |> Keyword.merge(request_opts)
    |> Keyword.put(:headers, merged_headers)
  end

  @nested_config_keys [:rate_limit, :circuit_breaker, :deduplicate]

  defp deep_merge_options(profile_config, user_opts) do
    Keyword.merge(profile_config, user_opts, fn key, profile_val, user_val ->
      if key in @nested_config_keys and is_list(profile_val) and is_list(user_val) do
        Keyword.merge(profile_val, user_val)
      else
        user_val
      end
    end)
  end

  @doc """
  Checks if HTTPower is currently in test mode.

  In test mode, real HTTP requests are blocked unless they include a `:plug` option
  for mocking with Req.Test.

  ## Examples

      Application.put_env(:httpower, :test_mode, true)
      HTTPower.test_mode?() # true

      Application.put_env(:httpower, :test_mode, false)
      HTTPower.test_mode?() # false

  """
  @spec test_mode?() :: boolean()
  def test_mode? do
    Application.get_env(:httpower, :test_mode, false)
  end
end

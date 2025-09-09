defmodule HTTPower do
  @moduledoc """
  A reliable HTTP client that wraps Req with advanced features.

  HTTPower provides a clean, production-ready HTTP client with advanced features like:

  - **Test mode blocking**: Prevents real HTTP requests during testing
  - **Smart retries**: Intelligent retry logic with configurable policies
  - **Clean error handling**: Never raises exceptions, always returns `{:ok, response}` or `{:error, reason}`
  - **SSL/Proxy support**: Full SSL verification and proxy configuration
  - **Request timeout management**: Configurable timeouts with sensible defaults

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
  """

  alias HTTPower.Client

  @doc """
  Makes an HTTP GET request.

  ## Options

  See module documentation for available options.

  ## Examples

      HTTPower.get("https://api.example.com/users")
      HTTPower.get("https://api.example.com/users", headers: %{"Authorization" => "Bearer token"})

  """
  @spec get(String.t(), keyword()) :: {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def get(url, opts \\ []) do
    Client.get(url, opts)
  end

  @doc """
  Makes an HTTP POST request.

  ## Options

  See module documentation for available options. Additionally supports:
  - `body` - Request body (string or form data)

  ## Examples

      HTTPower.post("https://api.example.com/users", body: "name=John")
      HTTPower.post("https://api.example.com/users", 
        body: Jason.encode!(%{name: "John"}),
        headers: %{"Content-Type" => "application/json"}
      )

  """
  @spec post(String.t(), keyword()) :: {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def post(url, opts \\ []) do
    Client.post(url, opts)
  end

  @doc """
  Makes an HTTP PUT request.

  ## Options

  See module documentation for available options. Additionally supports:
  - `body` - Request body (string or form data)

  ## Examples

      HTTPower.put("https://api.example.com/users/1", body: "name=John")

  """
  @spec put(String.t(), keyword()) :: {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def put(url, opts \\ []) do
    Client.put(url, opts)
  end

  @doc """
  Makes an HTTP DELETE request.

  ## Options

  See module documentation for available options.

  ## Examples

      HTTPower.delete("https://api.example.com/users/1")

  """
  @spec delete(String.t(), keyword()) ::
          {:ok, HTTPower.Response.t()} | {:error, HTTPower.Error.t()}
  def delete(url, opts \\ []) do
    Client.delete(url, opts)
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

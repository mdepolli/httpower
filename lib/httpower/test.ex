defmodule HTTPower.Test do
  # Suppress warnings for Plug functions when Plug is not loaded (e.g., in prod)
  @compile {:no_warn_undefined, [Plug.Conn, Plug.Test]}

  @moduledoc """
  Adapter-agnostic testing utilities for HTTPower.

  This module provides a testing interface that works independently of which
  adapter (Req, Tesla) you have installed. It allows you to write tests that
  mock HTTP requests without coupling to adapter-specific test utilities.

  ## Example

      defmodule MyApp.ApiClientTest do
        use ExUnit.Case

        setup do
          HTTPower.Test.setup()
        end

        test "fetches users" do
          HTTPower.Test.stub(fn conn ->
            case {conn.method, conn.request_path} do
              {"GET", "/users"} ->
                HTTPower.Test.json(conn, %{users: ["alice", "bob"]})

              {"POST", "/users"} ->
                HTTPower.Test.json(conn, %{created: true})
            end
          end)

          {:ok, response} = HTTPower.get("https://api.example.com/users")

          assert response.status == 200
          assert response.body == %{"users" => ["alice", "bob"]}
        end
      end

  ## Benefits

  - **Adapter independence**: No need to know if you're using Req or Tesla
  - **Simple API**: One `stub/1` function for all mocking needs
  - **Zero coupling**: Doesn't depend on Req.Test or Tesla.Mock
  - **Convenient helpers**: `json/2`, `html/2`, `text/2` for responses
  """

  @doc """
  Sets up HTTPower.Test for the current test.

  Call this in your test setup to enable HTTP mocking for that test.

  ## Example

      setup do
        HTTPower.Test.setup()
      end
  """
  def setup do
    import ExUnit.Callbacks, only: [on_exit: 1]

    # Store that this process is in test mode
    Process.put(:httpower_test_mock_enabled, true)

    on_exit(fn ->
      Process.delete(:httpower_test_mock_enabled)
      Process.delete(:httpower_test_stub)
    end)

    :ok
  end

  @doc """
  Registers a stub function to handle HTTP requests in tests.

  The stub function receives a `Plug.Conn` struct and should return a
  `Plug.Conn` with the response set using helper functions like `json/2`,
  `html/2`, or `text/2`.

  ## Example

      HTTPower.Test.stub(fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/weather"} ->
            HTTPower.Test.json(conn, %{temp: 25, condition: "sunny"})

          {"POST", "/users"} ->
            HTTPower.Test.json(conn, %{created: true}, status: 201)

          _ ->
            HTTPower.Test.json(conn, %{error: "not found"}, status: 404)
        end
      end)
  """
  def stub(fun) when is_function(fun, 1) do
    unless Process.get(:httpower_test_mock_enabled) do
      raise """
      HTTPower.Test.stub/1 called without calling HTTPower.Test.setup/0 first.

      Make sure to call HTTPower.Test.setup() in your test setup:

        setup do
          HTTPower.Test.setup()
        end
      """
    end

    Process.put(:httpower_test_stub, fun)
    :ok
  end

  @doc """
  Sends a JSON response with the given data.

  ## Options

    * `:status` - HTTP status code (default: 200)

  ## Examples

      HTTPower.Test.json(conn, %{success: true})
      HTTPower.Test.json(conn, %{error: "not found"}, status: 404)
  """
  def json(conn, data, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    body = Jason.encode!(data)

    conn
    |> Plug.Conn.put_resp_content_type("application/json", "utf-8")
    |> Plug.Conn.resp(status, body)
  end

  @doc """
  Sends an HTML response with the given data.

  ## Options

    * `:status` - HTTP status code (default: 200)

  ## Examples

      HTTPower.Test.html(conn, "<h1>Hello</h1>")
      HTTPower.Test.html(conn, "<h1>Not Found</h1>", status: 404)
  """
  def html(conn, data, opts \\ []) do
    status = Keyword.get(opts, :status, 200)

    conn
    |> Plug.Conn.put_resp_content_type("text/html", "utf-8")
    |> Plug.Conn.resp(status, data)
  end

  @doc """
  Sends a text response with the given data.

  ## Options

    * `:status` - HTTP status code (default: 200)

  ## Examples

      HTTPower.Test.text(conn, "Hello, World!")
      HTTPower.Test.text(conn, "Not Found", status: 404)
  """
  def text(conn, data, opts \\ []) do
    status = Keyword.get(opts, :status, 200)

    conn
    |> Plug.Conn.put_resp_content_type("text/plain", "utf-8")
    |> Plug.Conn.resp(status, data)
  end

  @doc """
  Simulates a network transport error.

  This function allows you to test how your application handles various
  network failures like timeouts, connection errors, and protocol issues.

  ## Supported error reasons

    * `:timeout` - Request timeout
    * `:closed` - Connection closed
    * `:econnrefused` - Connection refused
    * `:nxdomain` - DNS resolution failed

  ## Examples

      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.transport_error(conn, :timeout)
      end)

      {:error, error} = HTTPower.get("https://api.example.com/slow")
      assert error.reason == :test_transport_error
      assert error.message =~ "timeout"
  """
  def transport_error(conn, reason) do
    validate_transport_error!(reason)

    # Store the error in conn.private so execute_stub can detect it
    Plug.Conn.put_private(conn, :httpower_transport_error, reason)
  end

  defp validate_transport_error!(reason)
       when reason in [:timeout, :closed, :econnrefused, :nxdomain] do
    :ok
  end

  defp validate_transport_error!(reason) do
    raise ArgumentError, """
    Invalid transport error reason: #{inspect(reason)}

    Supported reasons: :timeout, :closed, :econnrefused, :nxdomain

    Example:
      HTTPower.Test.transport_error(conn, :timeout)
    """
  end

  @doc false
  # Internal function used by adapters to check if mocking is enabled
  def mock_enabled? do
    Process.get(:httpower_test_mock_enabled, false)
  end

  @doc false
  # Internal function used by adapters to get the stub function
  def get_stub do
    Process.get(:httpower_test_stub)
  end

  @doc false
  # Internal function used by adapters to execute a request through the stub
  def execute_stub(method, url, body, headers) do
    stub = get_stub()

    unless stub do
      raise """
      No stub registered. Call HTTPower.Test.stub/1 in your test.

      Example:

        HTTPower.Test.stub(fn conn ->
          HTTPower.Test.json(conn, %{success: true})
        end)
      """
    end

    run_stub(stub, method, url, body, headers)
  end

  defp run_stub(stub, method, url, body, headers) do
    conn = build_conn(method, url, body, headers)
    conn = stub.(conn)
    conn_to_result(conn)
  rescue
    error ->
      {:error,
       %HTTPower.Error{
         reason: :test_stub_error,
         message: Exception.message(error)
       }}
  end

  defp build_conn(method, url, body, headers) do
    prepared_headers = prepare_headers(headers, method)
    uri = URI.parse(url)
    path = uri.path || "/"

    Plug.Test.conn(atom_to_http_method(method), path, body || "")
    |> Map.put(:host, uri.host)
    |> Map.put(:port, uri.port)
    |> Map.put(:scheme, String.to_atom(uri.scheme || "https"))
    |> put_request_headers(prepared_headers)
    |> Map.put(:query_string, uri.query || "")
  end

  defp conn_to_result(conn) do
    case conn.private[:httpower_transport_error] do
      nil ->
        {:ok,
         %HTTPower.Response{
           status: conn.status || 200,
           headers: format_headers(conn.resp_headers),
           body: parse_body(conn.resp_body)
         }}

      reason ->
        {:error,
         %HTTPower.Error{
           reason: :test_transport_error,
           message: "Simulated transport error: #{reason}"
         }}
    end
  end

  defp atom_to_http_method(:get), do: "GET"
  defp atom_to_http_method(:post), do: "POST"
  defp atom_to_http_method(:put), do: "PUT"
  defp atom_to_http_method(:delete), do: "DELETE"
  defp atom_to_http_method(:patch), do: "PATCH"
  defp atom_to_http_method(:head), do: "HEAD"
  defp atom_to_http_method(:options), do: "OPTIONS"

  defp prepare_headers(headers, :post) do
    # Mimic adapter behavior: add default Content-Type for POST and connection: close
    default_post_headers = %{"Content-Type" => "application/x-www-form-urlencoded"}

    Map.merge(default_post_headers, headers || %{})
    |> Map.put("connection", "close")
  end

  defp prepare_headers(headers, _method) do
    # For other methods, just add connection: close
    Map.put(headers || %{}, "connection", "close")
  end

  defp put_request_headers(conn, headers) when is_map(headers) do
    Enum.reduce(headers, conn, fn {key, value}, acc ->
      Plug.Conn.put_req_header(acc, normalize_header(key), to_string(value))
    end)
  end

  defp put_request_headers(conn, _), do: conn

  defp normalize_header(key) when is_atom(key), do: key |> to_string() |> String.downcase()
  defp normalize_header(key) when is_binary(key), do: String.downcase(key)

  defp format_headers(headers) do
    # Req returns headers as lists of values, so we need to match that format
    Map.new(headers, fn {key, value} ->
      {key, if(is_list(value), do: value, else: [value])}
    end)
  end

  defp parse_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp parse_body(body), do: body
end

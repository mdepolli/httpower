defmodule HTTPower.Adapter.FinchTest do
  @moduledoc """
  Unit tests for HTTPower.Adapter.Finch module.

  These tests directly test the Finch adapter logic, including option building,
  header preparation, SSL configuration, proxy configuration, and response conversion.
  """

  use ExUnit.Case, async: true
  alias HTTPower.Adapter.Finch, as: FinchAdapter
  alias HTTPower.Response

  setup_all do
    Application.put_env(:httpower, :test_mode, true)
    :ok
  end

  setup do
    HTTPower.Test.setup()
    :ok
  end

  describe "request/5 with HTTPower.Test interception" do
    test "makes successful GET request" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, %Response{status: 200, body: body}} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])

      assert Jason.decode!(body) == %{"success" => true}
    end

    test "makes successful POST request with body" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{received: true})
      end)

      assert {:ok, %Response{status: 200}} =
               FinchAdapter.request(
                 :post,
                 "https://api.example.com/submit",
                 "test=data",
                 %{},
                 []
               )
    end

    test "makes successful PUT request" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{updated: true})
      end)

      assert {:ok, %Response{status: 200}} =
               FinchAdapter.request(:put, "https://api.example.com/users/1", "name=John", %{}, [])
    end

    test "makes successful DELETE request" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.text(conn, "", status: 204)
      end)

      assert {:ok, %Response{status: 204, body: ""}} =
               FinchAdapter.request(:delete, "https://api.example.com/users/1", nil, %{}, [])
    end
  end

  describe "request/5 with custom headers" do
    test "passes custom headers to request" do
      HTTPower.Test.stub(fn conn ->
        assert conn.req_headers |> Enum.into(%{}) |> Map.get("x-custom-header") == "test-value"
        HTTPower.Test.json(conn, %{success: true})
      end)

      headers = %{"x-custom-header" => "test-value"}

      assert {:ok, %Response{}} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, headers, [])
    end

    test "does not inject connection: close header" do
      HTTPower.Test.stub(fn conn ->
        connection_header = conn.req_headers |> Enum.into(%{}) |> Map.get("connection")
        assert connection_header == nil
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, %Response{}} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])
    end

    test "allows custom Content-Type to override default for POST" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        assert headers["content-type"] == "application/json"
        HTTPower.Test.json(conn, %{success: true})
      end)

      headers = %{"Content-Type" => "application/json"}

      assert {:ok, %Response{}} =
               FinchAdapter.request(:post, "https://api.example.com/submit", "{}", headers, [])
    end
  end

  describe "request/5 with timeout option" do
    test "uses default timeout when not specified" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      # Default is 60 seconds
      assert {:ok, %Response{}} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])
    end

    test "respects custom timeout option" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, %Response{}} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, %{}, timeout: 5)
    end
  end

  describe "response conversion" do
    test "converts response to HTTPower.Response" do
      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-custom", "value")
        |> HTTPower.Test.json(%{data: "test"})
      end)

      assert {:ok, response} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])

      assert %Response{} = response
      assert response.status == 200
      assert is_map(response.headers)
      assert response.headers["x-custom"] == ["value"]
      assert Jason.decode!(response.body) == %{"data" => "test"}
    end

    test "handles empty response body" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.text(conn, "", status: 204)
      end)

      assert {:ok, %Response{status: 204, body: ""}} =
               FinchAdapter.request(:get, "https://api.example.com/empty", nil, %{}, [])
    end

    test "handles various status codes" do
      for status <- [200, 201, 204, 400, 404, 500, 502] do
        HTTPower.Test.stub(fn conn ->
          HTTPower.Test.text(conn, "response", status: status)
        end)

        assert {:ok, %Response{status: ^status}} =
                 FinchAdapter.request(:get, "https://api.example.com/status", nil, %{}, [])
      end
    end
  end

  describe "error handling" do
    test "handles network errors gracefully" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %HTTPower.Error{reason: :test_transport_error}} =
               FinchAdapter.request(:get, "https://api.example.com/timeout", nil, %{}, [])
    end

    test "handles connection refused" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %HTTPower.Error{reason: :test_transport_error}} =
               FinchAdapter.request(:get, "https://api.example.com/refused", nil, %{}, [])
    end

    test "handles other transport errors" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.transport_error(conn, :closed)
      end)

      assert {:error, %HTTPower.Error{reason: :test_transport_error}} =
               FinchAdapter.request(:get, "https://api.example.com/closed", nil, %{}, [])
    end
  end

  describe "real-adapter transport error normalization" do
    setup do
      # Disable HTTPower.Test mocking so the request reaches the real Finch
      # adapter path (the interceptor short-circuits before do_request while
      # mocking is enabled).
      :ets.delete(:httpower_test_stubs, self())
      :ok
    end

    test "unwraps a transport error into a bare reason atom (retryable by HTTPower.Retry)" do
      url = closed_port_url()

      assert {:error, :econnrefused} =
               FinchAdapter.request(:get, url, nil, %{}, proxy: nil, timeout: 2)
    end
  end

  # Binds an ephemeral port, captures its number, then closes it so a
  # subsequent connection is reliably refused (econnrefused).
  defp closed_port_url do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    "http://127.0.0.1:#{port}/"
  end

  describe "body handling" do
    test "handles nil body (GET, DELETE)" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, %Response{}} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])
    end

    test "handles string body (POST, PUT)" do
      HTTPower.Test.stub(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body == "test=data"
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, %Response{}} =
               FinchAdapter.request(:post, "https://api.example.com/submit", "test=data", %{}, [])
    end

    test "handles JSON body" do
      HTTPower.Test.stub(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body =~ "name"
        HTTPower.Test.json(conn, %{success: true})
      end)

      json_body = Jason.encode!(%{name: "John"})

      assert {:ok, %Response{}} =
               FinchAdapter.request(
                 :post,
                 "https://api.example.com/users",
                 json_body,
                 %{"Content-Type" => "application/json"},
                 []
               )
    end
  end

  describe "integration with HTTPower.Test" do
    test "respects HTTPower.Test.stub configuration" do
      HTTPower.Test.stub(fn conn ->
        case conn.request_path do
          "/test" -> HTTPower.Test.json(conn, %{path: "test"})
          "/other" -> HTTPower.Test.json(conn, %{path: "other"})
          _ -> HTTPower.Test.json(conn, %{path: "default"})
        end
      end)

      assert {:ok, %Response{body: body}} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])

      assert Jason.decode!(body) == %{"path" => "test"}

      assert {:ok, %Response{body: body}} =
               FinchAdapter.request(:get, "https://api.example.com/other", nil, %{}, [])

      assert Jason.decode!(body) == %{"path" => "other"}

      assert {:ok, %Response{body: body}} =
               FinchAdapter.request(:get, "https://api.example.com/unknown", nil, %{}, [])

      assert Jason.decode!(body) == %{"path" => "default"}
    end
  end

  describe "real Finch request behavior" do
    setup do
      # Disable HTTPower.Test mocking so requests reach the real Finch adapter.
      :ets.delete(:httpower_test_stubs, self())
      :ok
    end

    test "sends no body (no Content-Length) for a bodyless GET" do
      port = start_capture_server()

      assert {:ok, %Response{status: 200}} =
               FinchAdapter.request(:get, "http://127.0.0.1:#{port}/", nil, %{}, [])

      assert_receive {:captured_request, raw}, 2000
      refute raw =~ ~r/content-length/i
    end

    test "accepts a pool_timeout option without error" do
      port = start_capture_server()

      assert {:ok, %Response{status: 200}} =
               FinchAdapter.request(:get, "http://127.0.0.1:#{port}/", nil, %{},
                 pool_timeout: 1_000
               )
    end
  end

  # One-shot TCP server: captures the raw request headers, sends a minimal
  # 200 response, and forwards the captured request to the test process.
  defp start_capture_server do
    test_pid = self()
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listen)
      raw = recv_until_headers(socket, "")
      send(test_pid, {:captured_request, raw})
      :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp recv_until_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      acc
    else
      case :gen_tcp.recv(socket, 0, 2000) do
        {:ok, data} -> recv_until_headers(socket, acc <> data)
        {:error, _} -> acc
      end
    end
  end
end

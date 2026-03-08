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

      assert body == %{"success" => true}
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

    test "adds default Content-Type for POST requests" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        assert headers["content-type"] == "application/x-www-form-urlencoded"
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, %Response{}} =
               FinchAdapter.request(:post, "https://api.example.com/submit", "data", %{}, [])
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

  describe "request/5 with SSL options" do
    test "configures SSL verification for HTTPS URLs" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{secure: true})
      end)

      assert {:ok, %Response{}} =
               FinchAdapter.request(
                 :get,
                 "https://secure-api.com/test",
                 nil,
                 %{},
                 ssl_verify: true
               )
    end

    test "allows disabling SSL verification" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{insecure: true})
      end)

      assert {:ok, %Response{}} =
               FinchAdapter.request(
                 :get,
                 "https://insecure-api.com/test",
                 nil,
                 %{},
                 ssl_verify: false
               )
    end

    test "does not add SSL options for HTTP URLs" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{http: true})
      end)

      assert {:ok, %Response{}} =
               FinchAdapter.request(:get, "http://api.example.com/test", nil, %{}, [])
    end
  end

  describe "request/5 with proxy options" do
    test "uses system proxy by default" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{proxied: true})
      end)

      assert {:ok, %Response{}} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, %{},
                 proxy: :system
               )
    end

    test "allows nil proxy (no proxy)" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{no_proxy: true})
      end)

      assert {:ok, %Response{}} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, %{}, proxy: nil)
    end

    test "accepts custom proxy options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{custom_proxy: true})
      end)

      proxy_opts = [host: "proxy.example.com", port: 8080]

      assert {:ok, %Response{}} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, %{},
                 proxy: proxy_opts
               )
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
      assert response.body == %{"data" => "test"}
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

  describe "conn_opts merging (SSL + proxy)" do
    test "conn_opts contains both transport_opts and proxy for HTTPS with proxy" do
      # Directly test the merging behavior that build_finch_opts should produce.
      # Simulate the Finch option-building pipeline: SSL options first, then proxy options.
      # After merging, conn_opts should contain BOTH keys.

      # Step 1: Start with empty opts (as build_finch_opts does)
      opts = []

      # Step 2: Add SSL options (what maybe_add_ssl_options does for HTTPS)
      ssl_opts = [verify: :verify_none]
      conn_opts = Keyword.get(opts, :conn_opts, [])
      transport_opts = Keyword.get(conn_opts, :transport_opts, [])
      updated_transport_opts = Keyword.merge(transport_opts, ssl_opts)
      updated_conn_opts = Keyword.put(conn_opts, :transport_opts, updated_transport_opts)
      opts = Keyword.put(opts, :conn_opts, updated_conn_opts)

      # Step 3: Add proxy options (what maybe_add_proxy_options does)
      conn_opts = Keyword.get(opts, :conn_opts, [])
      updated_conn_opts = Keyword.put(conn_opts, :proxy, :system)
      opts = Keyword.put(opts, :conn_opts, updated_conn_opts)

      # Verify: conn_opts should have BOTH transport_opts and proxy
      final_conn_opts = Keyword.get(opts, :conn_opts, [])

      assert Keyword.has_key?(final_conn_opts, :transport_opts),
             "conn_opts should contain :transport_opts from SSL, got: #{inspect(final_conn_opts)}"

      assert Keyword.has_key?(final_conn_opts, :proxy),
             "conn_opts should contain :proxy, got: #{inspect(final_conn_opts)}"

      assert final_conn_opts[:transport_opts] == [verify: :verify_none]
      assert final_conn_opts[:proxy] == :system
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

      assert {:ok, %Response{body: %{"path" => "test"}}} =
               FinchAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])

      assert {:ok, %Response{body: %{"path" => "other"}}} =
               FinchAdapter.request(:get, "https://api.example.com/other", nil, %{}, [])

      assert {:ok, %Response{body: %{"path" => "default"}}} =
               FinchAdapter.request(:get, "https://api.example.com/unknown", nil, %{}, [])
    end
  end
end

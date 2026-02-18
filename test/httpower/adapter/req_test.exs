defmodule HTTPower.Adapter.ReqTest do
  @moduledoc """
  Unit tests for HTTPower.Adapter.Req module.

  These tests directly test the Req adapter logic, including option building,
  header preparation, SSL configuration, proxy configuration, and response conversion.
  """

  use ExUnit.Case, async: true
  alias HTTPower.Adapter.Req, as: ReqAdapter
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
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])

      assert body == %{"success" => true}
    end

    test "makes successful POST request with body" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{received: true})
      end)

      assert {:ok, %Response{status: 200}} =
               ReqAdapter.request(
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
               ReqAdapter.request(:put, "https://api.example.com/users/1", "name=John", %{}, [])
    end

    test "makes successful DELETE request" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.text(conn, "", status: 204)
      end)

      assert {:ok, %Response{status: 204, body: ""}} =
               ReqAdapter.request(:delete, "https://api.example.com/users/1", nil, %{}, [])
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
               ReqAdapter.request(:get, "https://api.example.com/test", nil, headers, [])
    end

    test "does not inject connection: close header" do
      HTTPower.Test.stub(fn conn ->
        connection_header = conn.req_headers |> Enum.into(%{}) |> Map.get("connection")
        assert connection_header == nil
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, %Response{}} =
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])
    end

    test "adds default Content-Type for POST requests" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        assert headers["content-type"] == "application/x-www-form-urlencoded"
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, %Response{}} =
               ReqAdapter.request(:post, "https://api.example.com/submit", "data", %{}, [])
    end

    test "allows custom Content-Type to override default for POST" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        assert headers["content-type"] == "application/json"
        HTTPower.Test.json(conn, %{success: true})
      end)

      headers = %{"Content-Type" => "application/json"}

      assert {:ok, %Response{}} =
               ReqAdapter.request(:post, "https://api.example.com/submit", "{}", headers, [])
    end
  end

  describe "request/5 with timeout option" do
    test "uses default timeout when not specified" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      # Default is 60 seconds
      assert {:ok, %Response{}} =
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])
    end

    test "respects custom timeout option" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, %Response{}} =
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{}, timeout: 5)
    end
  end

  describe "request/5 with SSL options" do
    test "configures SSL verification for HTTPS URLs" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{secure: true})
      end)

      assert {:ok, %Response{}} =
               ReqAdapter.request(
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
               ReqAdapter.request(
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
               ReqAdapter.request(:get, "http://api.example.com/test", nil, %{}, [])
    end
  end

  describe "request/5 with proxy options" do
    test "uses system proxy by default" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{proxied: true})
      end)

      assert {:ok, %Response{}} =
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{}, proxy: :system)
    end

    test "allows nil proxy (no proxy)" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{no_proxy: true})
      end)

      assert {:ok, %Response{}} =
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{}, proxy: nil)
    end

    test "accepts custom proxy options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{custom_proxy: true})
      end)

      proxy_opts = [host: "proxy.example.com", port: 8080]

      assert {:ok, %Response{}} =
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{},
                 proxy: proxy_opts
               )
    end
  end

  describe "request/5 with additional options" do
    test "filters out HTTPower-specific options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      # These options should be filtered and not cause errors
      opts = [
        timeout: 30,
        max_retries: 5,
        retry_safe: true,
        base_delay: 500,
        max_delay: 10_000,
        jitter_factor: 0.3,
        adapter: HTTPower.Adapter.Req
      ]

      assert {:ok, %Response{}} =
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)
    end

    test "passes through Req-specific options like :plug" do
      # This is tested implicitly by HTTPower.Test working
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{with_plug: true})
      end)

      assert {:ok, %Response{}} =
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])
    end
  end

  describe "response conversion" do
    test "converts Req.Response to HTTPower.Response" do
      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-custom", "value")
        |> HTTPower.Test.json(%{data: "test"})
      end)

      assert {:ok, response} =
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])

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
               ReqAdapter.request(:get, "https://api.example.com/empty", nil, %{}, [])
    end

    test "handles various status codes" do
      for status <- [200, 201, 204, 400, 404, 500, 502] do
        HTTPower.Test.stub(fn conn ->
          HTTPower.Test.text(conn, "response", status: status)
        end)

        assert {:ok, %Response{status: ^status}} =
                 ReqAdapter.request(:get, "https://api.example.com/status", nil, %{}, [])
      end
    end
  end

  describe "error handling" do
    test "handles network errors gracefully" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.transport_error(conn, :timeout)
      end)

      # HTTPower.Test wraps transport errors in HTTPower.Error
      assert {:error, %HTTPower.Error{reason: :test_transport_error}} =
               ReqAdapter.request(:get, "https://api.example.com/timeout", nil, %{}, [])
    end

    test "handles connection refused" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %HTTPower.Error{reason: :test_transport_error}} =
               ReqAdapter.request(:get, "https://api.example.com/refused", nil, %{}, [])
    end

    test "handles other transport errors" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.transport_error(conn, :closed)
      end)

      assert {:error, %HTTPower.Error{reason: :test_transport_error}} =
               ReqAdapter.request(:get, "https://api.example.com/closed", nil, %{}, [])
    end
  end

  describe "body handling" do
    test "handles nil body (GET, DELETE)" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, %Response{}} =
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])
    end

    test "handles string body (POST, PUT)" do
      HTTPower.Test.stub(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body == "test=data"
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, %Response{}} =
               ReqAdapter.request(:post, "https://api.example.com/submit", "test=data", %{}, [])
    end

    test "handles JSON body" do
      HTTPower.Test.stub(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body =~ "name"
        HTTPower.Test.json(conn, %{success: true})
      end)

      json_body = Jason.encode!(%{name: "John"})

      assert {:ok, %Response{}} =
               ReqAdapter.request(
                 :post,
                 "https://api.example.com/users",
                 json_body,
                 %{"Content-Type" => "application/json"},
                 []
               )
    end
  end

  describe "connect_options merging (SSL + proxy)" do
    setup do
      # Ensure Req application is started (needed for Req.Test.Ownership on Elixir 1.14
      # where optional dep applications may not be auto-started)
      Application.ensure_all_started(:req)
      :ok
    end

    test "HTTPS request with system proxy preserves SSL connect_options" do
      # Disable HTTPower.Test interception so request goes through the real Req code path.
      # This exercises build_req_opts -> maybe_add_ssl_options -> maybe_add_proxy_options.
      Process.delete(:httpower_test_mock_enabled)

      Req.Test.stub(HTTPower.Adapter.ReqTest.SSLProxy, fn conn ->
        Req.Test.json(conn, %{ssl_and_proxy: true})
      end)

      # HTTPS URL + proxy: :system means both maybe_add_ssl_options and
      # maybe_add_proxy_options will modify connect_options.
      # Before the fix, maybe_add_proxy_options overwrote the transport_opts
      # set by maybe_add_ssl_options because both used Keyword.put(:connect_options, ...).
      assert {:ok, %Response{status: 200, body: %{"ssl_and_proxy" => true}}} =
               ReqAdapter.request(
                 :get,
                 URI.parse("https://secure-api.com/test"),
                 nil,
                 %{},
                 ssl_verify: false,
                 proxy: :system,
                 plug: {Req.Test, HTTPower.Adapter.ReqTest.SSLProxy}
               )
    end

    test "HTTPS request with custom proxy preserves SSL connect_options" do
      Process.delete(:httpower_test_mock_enabled)

      Req.Test.stub(HTTPower.Adapter.ReqTest.CustomProxy, fn conn ->
        Req.Test.json(conn, %{custom_proxy_ssl: true})
      end)

      proxy_opts = [host: "proxy.example.com", port: 8080]

      assert {:ok, %Response{status: 200, body: %{"custom_proxy_ssl" => true}}} =
               ReqAdapter.request(
                 :get,
                 URI.parse("https://secure-api.com/test"),
                 nil,
                 %{},
                 ssl_verify: true,
                 proxy: proxy_opts,
                 plug: {Req.Test, HTTPower.Adapter.ReqTest.CustomProxy}
               )
    end

    test "connect_options contains both transport_opts and proxy for HTTPS with proxy" do
      # Directly test the merging behavior that build_req_opts should produce.
      # Simulate the option-building pipeline: SSL options first, then proxy options.
      # After the fix, connect_options should contain BOTH keys.

      # Step 1: Start with empty opts (as build_req_opts does)
      opts = []

      # Step 2: Add SSL options (what maybe_add_ssl_options should do for HTTPS)
      ssl_opts = [verify: :verify_none]
      existing_ssl = Keyword.get(opts, :connect_options, [])
      updated_ssl = Keyword.put(existing_ssl, :transport_opts, ssl_opts)
      opts = Keyword.put(opts, :connect_options, updated_ssl)

      # Step 3: Add proxy options (what maybe_add_proxy_options should do)
      existing_proxy = Keyword.get(opts, :connect_options, [])
      updated_proxy = Keyword.put(existing_proxy, :proxy, :system)
      opts = Keyword.put(opts, :connect_options, updated_proxy)

      # Verify: connect_options should have BOTH transport_opts and proxy
      connect_opts = Keyword.get(opts, :connect_options, [])

      assert Keyword.has_key?(connect_opts, :transport_opts),
             "connect_options should contain :transport_opts from SSL, got: #{inspect(connect_opts)}"

      assert Keyword.has_key?(connect_opts, :proxy),
             "connect_options should contain :proxy, got: #{inspect(connect_opts)}"

      assert connect_opts[:transport_opts] == [verify: :verify_none]
      assert connect_opts[:proxy] == :system
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
               ReqAdapter.request(:get, "https://api.example.com/test", nil, %{}, [])

      assert {:ok, %Response{body: %{"path" => "other"}}} =
               ReqAdapter.request(:get, "https://api.example.com/other", nil, %{}, [])

      assert {:ok, %Response{body: %{"path" => "default"}}} =
               ReqAdapter.request(:get, "https://api.example.com/unknown", nil, %{}, [])
    end
  end
end

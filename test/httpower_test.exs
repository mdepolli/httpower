defmodule HTTPowerTest do
  use ExUnit.Case, async: true
  doctest HTTPower

  setup_all do
    Application.put_env(:httpower, :test_mode, true)
    :ok
  end

  describe "basic HTTP methods" do
    test "get/2 with test mode disabled" do
      # Use Req.Test.stub for controlled testing
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{status: "success", penguin: "🐧"})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test", plug: {Req.Test, HTTPower})

      assert response.status == 200
      assert response.body == %{"status" => "success", "penguin" => "🐧"}
    end

    test "get/2 with custom headers and timeout" do
      Req.Test.stub(HTTPower, fn conn ->
        # Verify custom headers are present
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
        assert Plug.Conn.get_req_header(conn, "connection") == ["close"]

        Req.Test.json(conn, %{success: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 headers: %{"Authorization" => "Bearer test-token"},
                 timeout: 30,
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end

    test "post/2 with body and headers" do
      Req.Test.stub(HTTPower, fn conn ->
        # Verify the request was correct
        assert conn.method == "POST"
        assert conn.request_path == "/submit"
        # Verify default Content-Type header is set
        assert Plug.Conn.get_req_header(conn, "content-type") == [
                 "application/x-www-form-urlencoded"
               ]

        Req.Test.json(conn, %{received: "data"})
      end)

      {:ok, response} =
        HTTPower.post("https://api.example.com/submit",
          body: "test=data",
          headers: %{"Authorization" => "Bearer token"},
          plug: {Req.Test, HTTPower}
        )

      assert response.status == 200
      assert response.body == %{"received" => "data"}
    end

    test "post/2 with custom content-type header" do
      Req.Test.stub(HTTPower, fn conn ->
        # Verify custom Content-Type overrides default
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

        Req.Test.json(conn, %{created: true})
      end)

      {:ok, response} =
        HTTPower.post("https://api.example.com/users",
          body: ~s({"name": "John"}),
          headers: %{"Content-Type" => "application/json"},
          plug: {Req.Test, HTTPower}
        )

      assert response.status == 200
    end

    test "put/2 with body" do
      Req.Test.stub(HTTPower, fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/users/1"

        Req.Test.json(conn, %{updated: true})
      end)

      {:ok, response} =
        HTTPower.put("https://api.example.com/users/1",
          body: "name=Jane",
          plug: {Req.Test, HTTPower}
        )

      assert response.status == 200
      assert response.body == %{"updated" => true}
    end

    test "put/2 without body" do
      Req.Test.stub(HTTPower, fn conn ->
        assert conn.method == "PUT"
        # Verify no body was sent
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body == ""

        Req.Test.json(conn, %{updated: true})
      end)

      {:ok, response} =
        HTTPower.put("https://api.example.com/users/1",
          plug: {Req.Test, HTTPower}
        )

      assert response.status == 200
    end

    test "delete/2 method" do
      Req.Test.stub(HTTPower, fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/users/1"

        conn
        |> Plug.Conn.resp(204, "")
      end)

      {:ok, response} =
        HTTPower.delete("https://api.example.com/users/1",
          plug: {Req.Test, HTTPower}
        )

      assert response.status == 204
      assert response.body == ""
    end
  end

  describe "test mode blocking" do
    setup do
      # Save original config
      original_config = Application.get_env(:httpower, :test_mode)

      on_exit(fn ->
        if original_config != nil do
          Application.put_env(:httpower, :test_mode, original_config)
        else
          Application.delete_env(:httpower, :test_mode)
        end
      end)

      :ok
    end

    test "blocks real requests when test_mode is true" do

      assert HTTPower.test_mode?() == true

      # Real request should be blocked
      assert {:error, error} = HTTPower.get("https://api.example.com/real")
      assert error.reason == :network_blocked
      assert error.message == "Network access blocked in test mode"
    end

    test "allows requests with plug even in test mode" do

      Req.Test.stub(HTTPower, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "Test response")
      end)

      # Request with plug should work even in test mode
      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 plug: {Req.Test, HTTPower}
               )

      assert response.body == "Test response"
    end

    test "allows real requests when test_mode is false" do
      Application.put_env(:httpower, :test_mode, false)

      assert HTTPower.test_mode?() == false

      # This would make a real request, but we'll stub it for this test
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{real: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://httpbin.org/json",
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end
  end

  describe "retry logic and error handling" do
    test "returns clean error tuples, never raises" do
      Req.Test.stub(HTTPower, fn _conn ->
        # Simulate network error
        raise "Network error"
      end)

      # Should return error tuple, not raise
      assert {:error, error} =
               HTTPower.get("https://api.example.com/error",
                 plug: {Req.Test, HTTPower}
               )

      assert %HTTPower.Error{} = error
    end

    test "handles different HTTP status codes" do
      test_cases = [
        {404, "Not Found"},
        {500, "Internal Server Error"},
        {502, "Bad Gateway"}
      ]

      for {status, status_text} <- test_cases do
        Req.Test.stub(HTTPower, fn conn ->
          conn
          |> Plug.Conn.resp(status, status_text)
        end)

        assert {:ok, response} =
                 HTTPower.get("https://api.example.com/status",
                   plug: {Req.Test, HTTPower}
                 )

        assert response.status == status
        assert response.body == status_text
      end
    end

    test "error handling for malformed responses" do
      Req.Test.stub(HTTPower, fn _conn ->
        # Return malformed data that causes issues
        raise ArgumentError, "Bad response format"
      end)

      assert {:error, error} =
               HTTPower.get("https://api.example.com/malformed",
                 max_retries: 0,
                 plug: {Req.Test, HTTPower}
               )

      assert %HTTPower.Error{} = error
      assert is_binary(error.message)
    end

    test "successfully handles response headers" do
      Req.Test.stub(HTTPower, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-custom-header", "test-value")
        |> Req.Test.json(%{data: "test"})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/headers",
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
      assert response.headers["x-custom-header"] == ["test-value"]
      assert response.body == %{"data" => "test"}
    end

    test "handles empty response body" do
      Req.Test.stub(HTTPower, fn conn ->
        conn
        |> Plug.Conn.resp(204, "")
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/empty",
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 204
      assert response.body == ""
    end

    test "handles large response bodies" do
      large_body = String.duplicate("data", 1000)

      Req.Test.stub(HTTPower, fn conn ->
        conn
        |> Plug.Conn.resp(200, large_body)
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/large",
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
      assert response.body == large_body
      assert byte_size(response.body) == 4000
    end
  end

  describe "SSL and proxy configuration" do
    test "configures SSL verification for HTTPS URLs" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{secure: true})
      end)

      # Test with SSL verification enabled (default)
      assert {:ok, response} =
               HTTPower.get("https://secure-api.com/test",
                 ssl_verify: true,
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end

    test "disables SSL verification when configured" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{insecure: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://insecure-api.com/test",
                 ssl_verify: false,
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end

    test "does not configure SSL for HTTP URLs" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{http: true})
      end)

      assert {:ok, response} =
               HTTPower.get("http://api.example.com/test",
                 ssl_verify: true,
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end

    test "configures system proxy" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{proxied: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 proxy: :system,
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end

    test "configures custom proxy settings" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{custom_proxy: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 proxy: [host: "proxy.example.com", port: 8080],
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end

    test "handles nil proxy configuration" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{no_proxy: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 proxy: nil,
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end

    test "handles invalid proxy configuration" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{invalid_proxy: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 proxy: "invalid",
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end
  end

  describe "configuration" do
    test "test_mode?/0 reflects application config" do
      assert HTTPower.test_mode?() == true

      Application.put_env(:httpower, :test_mode, false)
      assert HTTPower.test_mode?() == false

      Application.delete_env(:httpower, :test_mode)
      assert HTTPower.test_mode?() == false
    end
  end

  describe "edge cases and options" do
    test "handles all default options" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{defaults: true})
      end)

      # Test with no options - should use all defaults
      assert {:ok, response} =
               HTTPower.get("https://api.example.com/defaults",
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end

    test "handles max_retries set to 0" do
      Req.Test.stub(HTTPower, fn _conn ->
        raise "Should not retry"
      end)

      # With max_retries: 0, should fail immediately
      assert {:error, error} =
               HTTPower.get("https://api.example.com/no-retry",
                 max_retries: 0,
                 plug: {Req.Test, HTTPower}
               )

      assert %HTTPower.Error{} = error
    end

    test "handles custom timeout values" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{timeout: true})
      end)

      # Test different timeout values
      for timeout <- [1, 30, 120] do
        assert {:ok, response} =
                 HTTPower.get("https://api.example.com/timeout",
                   timeout: timeout,
                   plug: {Req.Test, HTTPower}
                 )

        assert response.status == 200
      end
    end

    test "handles unknown error types with inspect" do
      complex_error = %{nested: %{data: "test"}, list: [1, 2, 3]}

      Req.Test.stub(HTTPower, fn _conn ->
        raise complex_error
      end)

      assert {:error, error} =
               HTTPower.get("https://api.example.com/complex",
                 max_retries: 0,
                 plug: {Req.Test, HTTPower}
               )

      assert %HTTPower.Error{} = error
      assert is_binary(error.message)
    end

    test "headers are properly merged for non-POST requests" do
      Req.Test.stub(HTTPower, fn conn ->
        # Verify connection: close header is added for non-POST
        assert Plug.Conn.get_req_header(conn, "connection") == ["close"]
        assert Plug.Conn.get_req_header(conn, "custom-header") == ["custom-value"]

        Req.Test.json(conn, %{success: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/headers",
                 headers: %{"Custom-Header" => "custom-value"},
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end
  end

  describe "configured clients" do
    test "HTTPower.new/1 creates a client struct" do
      client = HTTPower.new(base_url: "https://api.example.com")
      assert %HTTPower{base_url: "https://api.example.com", options: []} = client
    end

    test "HTTPower.new/1 accepts additional options" do
      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"Authorization" => "Bearer token"},
          timeout: 30
        )

      assert %HTTPower{
               base_url: "https://api.example.com",
               options: [headers: %{"Authorization" => "Bearer token"}, timeout: 30]
             } = client
    end

    test "client GET requests work with base_url and relative paths" do

      Req.Test.stub(HTTPower, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/users"
        Req.Test.json(conn, %{users: []})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")
      assert {:ok, response} = HTTPower.get(client, "/users", plug: {Req.Test, HTTPower})
      assert response.status == 200
      assert response.body == %{"users" => []}
    end

    test "client POST requests merge options correctly" do

      Req.Test.stub(HTTPower, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/users"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer token"]
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
        Req.Test.json(conn, %{created: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"Authorization" => "Bearer token"}
        )

      assert {:ok, response} =
               HTTPower.post(client, "/users",
                 body: Jason.encode!(%{name: "John"}),
                 headers: %{"Content-Type" => "application/json"},
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
      assert response.body == %{"created" => true}
    end

    test "client options override client defaults" do

      Req.Test.stub(HTTPower, fn conn ->
        assert conn.method == "GET"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer override-token"]
        Req.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"Authorization" => "Bearer default-token"}
        )

      assert {:ok, response} =
               HTTPower.get(client, "/users",
                 headers: %{"Authorization" => "Bearer override-token"},
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
    end

    test "client without base_url uses full path as URL" do

      Req.Test.stub(HTTPower, fn conn ->
        assert conn.method == "GET"
        assert conn.host == "different-api.com"
        assert conn.request_path == "/data"
        Req.Test.json(conn, %{data: "test"})
      end)

      client = HTTPower.new(timeout: 30)

      assert {:ok, response} =
               HTTPower.get(client, "https://different-api.com/data", plug: {Req.Test, HTTPower})

      assert response.status == 200
      assert response.body == %{"data" => "test"}
    end

    test "client works with all HTTP methods" do

      Req.Test.stub(HTTPower, fn conn ->
        case conn.method do
          "GET" -> Req.Test.json(conn, %{method: "get"})
          "POST" -> Req.Test.json(conn, %{method: "post"})
          "PUT" -> Req.Test.json(conn, %{method: "put"})
          "DELETE" -> Req.Test.json(conn, %{method: "delete"})
        end
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, response} = HTTPower.get(client, "/test", plug: {Req.Test, HTTPower})
      assert response.body == %{"method" => "get"}

      assert {:ok, response} = HTTPower.post(client, "/test", plug: {Req.Test, HTTPower})
      assert response.body == %{"method" => "post"}

      assert {:ok, response} = HTTPower.put(client, "/test", plug: {Req.Test, HTTPower})
      assert response.body == %{"method" => "put"}

      assert {:ok, response} = HTTPower.delete(client, "/test", plug: {Req.Test, HTTPower})
      assert response.body == %{"method" => "delete"}
    end

    test "client URL building with different path formats" do

      Req.Test.stub(HTTPower, fn conn ->
        assert conn.host == "api.example.com"
        Req.Test.json(conn, %{path: conn.request_path})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      # Test absolute path (starting with /)
      assert {:ok, response} = HTTPower.get(client, "/users", plug: {Req.Test, HTTPower})
      assert response.body == %{"path" => "/users"}

      # Test relative path (not starting with /)
      assert {:ok, response} = HTTPower.get(client, "posts", plug: {Req.Test, HTTPower})
      assert response.body == %{"path" => "/posts"}

      # Test empty path
      assert {:ok, response} = HTTPower.get(client, "", plug: {Req.Test, HTTPower})
      assert response.body == %{"path" => nil}
    end
  end

  describe "HTTP status code retries" do
    test "retries on 500 server errors" do

      attempt_count = Agent.start_link(fn -> 0 end)
      {:ok, pid} = attempt_count

      Req.Test.stub(HTTPower, fn conn ->
        Agent.update(pid, &(&1 + 1))
        current_attempt = Agent.get(pid, & &1)

        if current_attempt <= 2 do
          Plug.Conn.resp(conn, 500, "Server Error")
        else
          Req.Test.json(conn, %{success: true})
        end
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 max_retries: 3,
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
      assert response.body == %{"success" => true}
      assert Agent.get(pid, & &1) == 3
    end

    test "retries on 502 bad gateway errors" do

      attempt_count = Agent.start_link(fn -> 0 end)
      {:ok, pid} = attempt_count

      Req.Test.stub(HTTPower, fn conn ->
        Agent.update(pid, &(&1 + 1))
        current_attempt = Agent.get(pid, & &1)

        if current_attempt <= 1 do
          Plug.Conn.resp(conn, 502, "Bad Gateway")
        else
          Req.Test.json(conn, %{recovered: true})
        end
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 max_retries: 2,
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
      assert response.body == %{"recovered" => true}
      assert Agent.get(pid, & &1) == 2
    end

    test "does not retry on 4xx client errors" do

      attempt_count = Agent.start_link(fn -> 0 end)
      {:ok, pid} = attempt_count

      Req.Test.stub(HTTPower, fn conn ->
        Agent.update(pid, &(&1 + 1))
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 max_retries: 3,
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 404
      assert Agent.get(pid, & &1) == 1  # Only one attempt, no retries
    end

    test "retries multiple HTTP status codes" do

      status_codes = [503, 504, 500, 200]
      attempt_count = Agent.start_link(fn -> 0 end)
      {:ok, pid} = attempt_count

      Req.Test.stub(HTTPower, fn conn ->
        current_attempt = Agent.get(pid, & &1)
        Agent.update(pid, &(&1 + 1))
        
        status = Enum.at(status_codes, current_attempt)
        
        if status == 200 do
          Req.Test.json(conn, %{final: true})
        else
          Plug.Conn.resp(conn, status, "Error #{status}")
        end
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 max_retries: 4,
                 plug: {Req.Test, HTTPower}
               )

      assert response.status == 200
      assert response.body == %{"final" => true}
      assert Agent.get(pid, & &1) == 4  # 3 retries + 1 success
    end
  end
end

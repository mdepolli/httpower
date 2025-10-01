defmodule HTTPowerTest do
  use ExUnit.Case, async: true
  doctest HTTPower

  setup do
    HTTPower.Test.setup()
  end

  describe "basic HTTP methods" do
    test "get/2 with test mode disabled" do
      # Use Req.Test.stub for controlled testing
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{status: "success", penguin: "🐧"})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test")

      assert response.status == 200
      assert response.body == %{"status" => "success", "penguin" => "🐧"}
    end

    test "get/2 with custom headers and timeout" do
      HTTPower.Test.stub(fn conn ->
        # Verify custom headers are present
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
        assert Plug.Conn.get_req_header(conn, "connection") == ["close"]

        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 headers: %{"Authorization" => "Bearer test-token"},
                 timeout: 30
               )

      assert response.status == 200
    end

    test "post/2 with body and headers" do
      HTTPower.Test.stub(fn conn ->
        # Verify the request was correct
        assert conn.method == "POST"
        assert conn.request_path == "/submit"
        # Verify default Content-Type header is set
        assert Plug.Conn.get_req_header(conn, "content-type") == [
                 "application/x-www-form-urlencoded"
               ]

        HTTPower.Test.json(conn, %{received: "data"})
      end)

      {:ok, response} =
        HTTPower.post("https://api.example.com/submit",
          body: "test=data",
          headers: %{"Authorization" => "Bearer token"}
        )

      assert response.status == 200
      assert response.body == %{"received" => "data"}
    end

    test "post/2 with custom content-type header" do
      HTTPower.Test.stub(fn conn ->
        # Verify custom Content-Type overrides default
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

        HTTPower.Test.json(conn, %{created: true})
      end)

      {:ok, response} =
        HTTPower.post("https://api.example.com/users",
          body: ~s({"name": "John"}),
          headers: %{"Content-Type" => "application/json"}
        )

      assert response.status == 200
    end

    test "put/2 with body" do
      HTTPower.Test.stub(fn conn ->
        assert conn.method == "PUT"
        assert conn.request_path == "/users/1"

        HTTPower.Test.json(conn, %{updated: true})
      end)

      {:ok, response} =
        HTTPower.put("https://api.example.com/users/1",
          body: "name=Jane"
        )

      assert response.status == 200
      assert response.body == %{"updated" => true}
    end

    test "put/2 without body" do
      HTTPower.Test.stub(fn conn ->
        assert conn.method == "PUT"
        # Verify no body was sent
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body == ""

        HTTPower.Test.json(conn, %{updated: true})
      end)

      {:ok, response} =
        HTTPower.put("https://api.example.com/users/1")

      assert response.status == 200
    end

    test "delete/2 method" do
      HTTPower.Test.stub(fn conn ->
        assert conn.method == "DELETE"
        assert conn.request_path == "/users/1"

        conn
        |> Plug.Conn.resp(204, "")
      end)

      {:ok, response} =
        HTTPower.delete("https://api.example.com/users/1")

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
      Application.put_env(:httpower, :test_mode, true)

      assert HTTPower.test_mode?() == true

      # Temporarily disable HTTPower.Test mocking to test the blocking feature
      Process.delete(:httpower_test_mock_enabled)
      Process.delete(:httpower_test_stub)

      # Real request should be blocked
      assert {:error, error} = HTTPower.get("https://api.example.com/real")
      assert error.reason == :network_blocked
      assert error.message == "Network access blocked in test mode"

      # Re-enable mocking for subsequent tests
      Process.put(:httpower_test_mock_enabled, true)
    end

    test "allows requests with plug even in test mode" do
      Application.put_env(:httpower, :test_mode, true)

      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "Test response")
      end)

      # Request with plug should work even in test mode
      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test")

      assert response.body == "Test response"
    end

    test "allows real requests when test_mode is false" do
      Application.put_env(:httpower, :test_mode, false)

      assert HTTPower.test_mode?() == false

      # This would make a real request, but we'll stub it for this test
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{real: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://httpbin.org/json")

      assert response.status == 200
    end
  end

  describe "retry logic and error handling" do
    test "returns clean error tuples, never raises" do
      HTTPower.Test.stub(fn _conn ->
        # Simulate network error
        raise "Network error"
      end)

      # Should return error tuple, not raise
      assert {:error, error} =
               HTTPower.get("https://api.example.com/error")

      assert %HTTPower.Error{} = error
    end

    test "simulates transport errors with transport_error/2" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.transport_error(conn, :timeout)
      end)

      assert {:error, error} =
               HTTPower.get("https://api.example.com/slow")

      assert %HTTPower.Error{} = error
      assert error.reason == :test_transport_error
      assert error.message == "Simulated transport error: timeout"
    end

    test "validates transport error reasons" do
      # The validation happens when calling transport_error, so we test it directly
      conn = Plug.Test.conn("GET", "/test")

      assert_raise ArgumentError, ~r/Invalid transport error reason/, fn ->
        HTTPower.Test.transport_error(conn, :invalid_reason)
      end
    end

    test "simulates different transport error types" do
      error_types = [:timeout, :closed, :econnrefused, :nxdomain]

      for error_type <- error_types do
        HTTPower.Test.stub(fn conn ->
          HTTPower.Test.transport_error(conn, error_type)
        end)

        assert {:error, %HTTPower.Error{} = error} =
                 HTTPower.get("https://api.example.com/test")

        assert error.reason == :test_transport_error
        assert error.message == "Simulated transport error: #{error_type}"
      end
    end

    test "handles different HTTP status codes" do
      test_cases = [
        {404, "Not Found"},
        {500, "Internal Server Error"},
        {502, "Bad Gateway"}
      ]

      for {status, status_text} <- test_cases do
        HTTPower.Test.stub(fn conn ->
          conn
          |> Plug.Conn.resp(status, status_text)
        end)

        assert {:ok, response} =
                 HTTPower.get("https://api.example.com/status")

        assert response.status == status
        assert response.body == status_text
      end
    end

    test "error handling for malformed responses" do
      HTTPower.Test.stub(fn _conn ->
        # Return malformed data that causes issues
        raise ArgumentError, "Bad response format"
      end)

      assert {:error, error} =
               HTTPower.get("https://api.example.com/malformed",
                 max_retries: 0
               )

      assert %HTTPower.Error{} = error
      assert is_binary(error.message)
    end

    test "successfully handles response headers" do
      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-custom-header", "test-value")
        |> HTTPower.Test.json(%{data: "test"})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/headers")

      assert response.status == 200
      assert response.headers["x-custom-header"] == ["test-value"]
      assert response.body == %{"data" => "test"}
    end

    test "handles empty response body" do
      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.resp(204, "")
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/empty")

      assert response.status == 204
      assert response.body == ""
    end

    test "handles large response bodies" do
      large_body = String.duplicate("data", 1000)

      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.resp(200, large_body)
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/large")

      assert response.status == 200
      assert response.body == large_body
      assert byte_size(response.body) == 4000
    end
  end

  describe "SSL and proxy configuration" do
    test "configures SSL verification for HTTPS URLs" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{secure: true})
      end)

      # Test with SSL verification enabled (default)
      assert {:ok, response} =
               HTTPower.get("https://secure-api.com/test",
                 ssl_verify: true
               )

      assert response.status == 200
    end

    test "disables SSL verification when configured" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{insecure: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://insecure-api.com/test",
                 ssl_verify: false
               )

      assert response.status == 200
    end

    test "does not configure SSL for HTTP URLs" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{http: true})
      end)

      assert {:ok, response} =
               HTTPower.get("http://api.example.com/test",
                 ssl_verify: true
               )

      assert response.status == 200
    end

    test "configures system proxy" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{proxied: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 proxy: :system
               )

      assert response.status == 200
    end

    test "configures custom proxy settings" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{custom_proxy: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 proxy: [host: "proxy.example.com", port: 8080]
               )

      assert response.status == 200
    end

    test "handles nil proxy configuration" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{no_proxy: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 proxy: nil
               )

      assert response.status == 200
    end

    test "handles invalid proxy configuration" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{invalid_proxy: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test",
                 proxy: "invalid"
               )

      assert response.status == 200
    end
  end

  describe "configuration" do
    test "test_mode?/0 reflects application config" do
      Application.put_env(:httpower, :test_mode, true)
      assert HTTPower.test_mode?() == true

      Application.put_env(:httpower, :test_mode, false)
      assert HTTPower.test_mode?() == false

      Application.delete_env(:httpower, :test_mode)
      assert HTTPower.test_mode?() == false
    end
  end

  describe "edge cases and options" do
    test "handles all default options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{defaults: true})
      end)

      # Test with no options - should use all defaults
      assert {:ok, response} =
               HTTPower.get("https://api.example.com/defaults")

      assert response.status == 200
    end

    test "handles max_retries set to 0" do
      HTTPower.Test.stub(fn _conn ->
        raise "Should not retry"
      end)

      # With max_retries: 0, should fail immediately
      assert {:error, error} =
               HTTPower.get("https://api.example.com/no-retry",
                 max_retries: 0
               )

      assert %HTTPower.Error{} = error
    end

    test "handles custom timeout values" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{timeout: true})
      end)

      # Test different timeout values
      for timeout <- [1, 30, 120] do
        assert {:ok, response} =
                 HTTPower.get("https://api.example.com/timeout",
                   timeout: timeout
                 )

        assert response.status == 200
      end
    end

    test "handles unknown error types with inspect" do
      complex_error = %{nested: %{data: "test"}, list: [1, 2, 3]}

      HTTPower.Test.stub(fn _conn ->
        raise complex_error
      end)

      assert {:error, error} =
               HTTPower.get("https://api.example.com/complex",
                 max_retries: 0
               )

      assert %HTTPower.Error{} = error
      assert is_binary(error.message)
    end

    test "headers are properly merged for non-POST requests" do
      HTTPower.Test.stub(fn conn ->
        # Verify connection: close header is added for non-POST
        assert Plug.Conn.get_req_header(conn, "connection") == ["close"]
        assert Plug.Conn.get_req_header(conn, "custom-header") == ["custom-value"]

        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/headers",
                 headers: %{"Custom-Header" => "custom-value"}
               )

      assert response.status == 200
    end
  end

  describe "Retry-After header respect" do
    test "respects Retry-After header on 429 responses" do
      # Track call count to verify retry behavior
      call_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = call_count

      HTTPower.Test.stub(fn conn ->
        count = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if count == 0 do
          # First call: return 429 with Retry-After header
          conn
          |> Plug.Conn.put_resp_header("retry-after", "2")
          |> Plug.Conn.resp(429, "Too Many Requests")
        else
          # Subsequent calls: success
          HTTPower.Test.json(conn, %{success: true})
        end
      end)

      start_time = System.monotonic_time(:millisecond)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/rate-limited",
                 base_delay: 1000,
                 max_delay: 30_000
               )

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      assert response.status == 200
      # Should wait ~2 seconds (2000ms) as instructed by Retry-After
      # Allow margin for test execution time + request processing
      assert duration >= 1800 and duration <= 2700

      # Verify we made 2 calls (first 429, then success)
      assert Agent.get(agent, & &1) == 2
    end

    test "respects Retry-After header on 503 responses" do
      call_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = call_count

      HTTPower.Test.stub(fn conn ->
        count = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if count == 0 do
          # First call: return 503 with Retry-After header
          conn
          |> Plug.Conn.put_resp_header("retry-after", "1")
          |> Plug.Conn.resp(503, "Service Unavailable")
        else
          # Second call: success
          HTTPower.Test.json(conn, %{recovered: true})
        end
      end)

      start_time = System.monotonic_time(:millisecond)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/service-unavailable")

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      assert response.status == 200
      # Should wait ~1 second (1000ms) as instructed by Retry-After
      assert duration >= 900 and duration <= 1500

      assert Agent.get(agent, & &1) == 2
    end

    test "falls back to exponential backoff when Retry-After header missing on 429" do
      call_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = call_count

      HTTPower.Test.stub(fn conn ->
        count = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if count == 0 do
          # First call: return 429 WITHOUT Retry-After header
          conn
          |> Plug.Conn.resp(429, "Too Many Requests")
        else
          # Second call: success
          HTTPower.Test.json(conn, %{success: true})
        end
      end)

      start_time = System.monotonic_time(:millisecond)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/rate-limited-no-header",
                 base_delay: 500,
                 max_delay: 30_000
               )

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      assert response.status == 200
      # Should use exponential backoff (~500ms for first retry, attempt 1)
      # With jitter, expect 400-500ms
      assert duration >= 400 and duration <= 700

      assert Agent.get(agent, & &1) == 2
    end

    test "respects large Retry-After values" do
      call_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = call_count

      HTTPower.Test.stub(fn conn ->
        count = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if count == 0 do
          # First call: return 429 with large Retry-After (3 seconds)
          conn
          |> Plug.Conn.put_resp_header("retry-after", "3")
          |> Plug.Conn.resp(429, "Too Many Requests")
        else
          HTTPower.Test.json(conn, %{success: true})
        end
      end)

      start_time = System.monotonic_time(:millisecond)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/rate-limited-large")

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      assert response.status == 200
      # Should wait ~3 seconds (3000ms)
      # Allow margin for test execution time + request processing
      assert duration >= 2800 and duration <= 3700

      assert Agent.get(agent, & &1) == 2
    end

    test "uses exponential backoff for non-429/503 retryable status codes" do
      call_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = call_count

      HTTPower.Test.stub(fn conn ->
        count = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if count == 0 do
          # First call: return 500 (retryable, but not 429/503)
          conn
          |> Plug.Conn.put_resp_header("retry-after", "10")
          |> Plug.Conn.resp(500, "Internal Server Error")
        else
          HTTPower.Test.json(conn, %{recovered: true})
        end
      end)

      start_time = System.monotonic_time(:millisecond)

      assert {:ok, response} =
               HTTPower.get("https://api.example.com/server-error",
                 base_delay: 500,
                 max_delay: 30_000
               )

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      assert response.status == 200
      # Should use exponential backoff, NOT the Retry-After header
      # 500ms base delay for first retry, with jitter
      assert duration >= 350 and duration <= 750

      assert Agent.get(agent, & &1) == 2
    end
  end
end

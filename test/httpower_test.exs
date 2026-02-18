defmodule HTTPowerTest do
  use ExUnit.Case, async: true
  doctest HTTPower

  alias HTTPower.TelemetryTestHelper

  setup do
    HTTPower.Test.setup()
  end

  # Helper to flush mailbox and ignore telemetry events from other concurrent tests
  defp flush_mailbox do
    receive do
      {:telemetry, _, _, _} -> flush_mailbox()
    after
      0 -> :ok
    end
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

    test "patch/2 makes a PATCH request" do
      HTTPower.Test.stub(fn conn ->
        assert conn.method == "PATCH"
        HTTPower.Test.json(conn, %{patched: true})
      end)

      assert {:ok, %HTTPower.Response{status: 200, body: %{"patched" => true}}} =
               HTTPower.patch("https://api.example.com/users/1", body: "name=Jane")
    end

    test "head/2 makes a HEAD request" do
      HTTPower.Test.stub(fn conn ->
        assert conn.method == "HEAD"
        HTTPower.Test.text(conn, "")
      end)

      assert {:ok, %HTTPower.Response{status: 200}} =
               HTTPower.head("https://api.example.com/users")
    end

    test "options/2 makes an OPTIONS request" do
      HTTPower.Test.stub(fn conn ->
        assert conn.method == "OPTIONS"
        HTTPower.Test.text(conn, "")
      end)

      assert {:ok, %HTTPower.Response{status: 200}} =
               HTTPower.options("https://api.example.com/users")
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

  describe "telemetry - HTTP request lifecycle events" do
    setup do
      # Attach telemetry handler to capture events
      ref = make_ref()
      test_pid = self()

      events = [
        [:httpower, :request, :start],
        [:httpower, :request, :stop],
        [:httpower, :request, :exception]
      ]

      :telemetry.attach_many(
        ref,
        events,
        &TelemetryTestHelper.forward_event/4,
        %{test_pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      %{ref: ref}
    end

    test "emits start and stop events for successful request" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      HTTPower.get("https://httpbin.org/get")

      assert_received {:telemetry, [:httpower, :request, :start], measurements, metadata}
      assert measurements.system_time
      assert metadata.method == :get
      assert metadata.url == "https://httpbin.org/get"

      assert_received {:telemetry, [:httpower, :request, :stop], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.status == 200
      assert metadata.method == :get
    end

    test "emits stop event for 500 error response" do
      # Flush mailbox to ignore events from other concurrent tests
      flush_mailbox()

      HTTPower.Test.stub(fn conn ->
        Plug.Conn.resp(conn, 500, "Server Error")
      end)

      test_url = "https://httpbin.org/status/500"

      # 500 will be retried then return ok with 500 status
      {:ok, response} = HTTPower.get(test_url)
      assert response.status == 500

      # Match on URL to ensure we get events from THIS test, not other concurrent tests
      assert_received {:telemetry, [:httpower, :request, :start], _, %{url: ^test_url}}

      # 500 is a valid HTTP response, so we get stop event with status 500
      assert_received {:telemetry, [:httpower, :request, :stop], measurements,
                       %{url: ^test_url} = metadata}

      assert measurements.duration > 0
      assert metadata.status == 500
      assert metadata.method == :get
    end

    test "sanitizes URLs in telemetry metadata" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      HTTPower.get("https://api.example.com/users?token=secret&page=1")

      assert_received {:telemetry, [:httpower, :request, :start], _, metadata}
      # URL should be sanitized (no query params)
      assert metadata.url == "https://api.example.com/users"
    end
  end

  describe "HTTPower.new/1 - client configuration" do
    test "creates client with base_url only" do
      client = HTTPower.new(base_url: "https://api.example.com")

      assert %HTTPower{base_url: "https://api.example.com", options: []} = client
    end

    test "creates client with base_url and options" do
      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          timeout: 30,
          max_retries: 5
        )

      assert %HTTPower{base_url: "https://api.example.com"} = client
      assert client.options[:timeout] == 30
      assert client.options[:max_retries] == 5
    end

    test "creates client with headers" do
      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"Authorization" => "Bearer token"}
        )

      assert client.options[:headers] == %{"Authorization" => "Bearer token"}
    end

    test "creates client without base_url" do
      client = HTTPower.new(timeout: 30)

      assert %HTTPower{base_url: nil, options: [timeout: 30]} = client
    end

    test "creates empty client" do
      client = HTTPower.new()

      assert %HTTPower{base_url: nil, options: []} = client
    end

    test "deep merges nested keyword list options from profiles" do
      client =
        HTTPower.new(
          profile: :high_volume_api,
          rate_limit: [strategy: :error]
        )

      rate_config = Keyword.get(client.options, :rate_limit, [])
      assert Keyword.get(rate_config, :strategy) == :error
      assert Keyword.get(rate_config, :requests) == 1000
    end
  end

  describe "3-arity GET: get(client, path, opts)" do
    test "makes request with client, path, and additional options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"X-Client-Header" => "client-value"}
        )

      assert {:ok, response} =
               HTTPower.get(client, "/users", headers: %{"X-Request-Header" => "request-value"})

      assert response.status == 200
    end

    test "merges client headers with request headers" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        # Both headers should be present
        assert headers["x-client-header"] == "client-value"
        assert headers["x-request-header"] == "request-value"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"X-Client-Header" => "client-value"}
        )

      assert {:ok, _response} =
               HTTPower.get(client, "/test", headers: %{"X-Request-Header" => "request-value"})
    end

    test "request headers override client headers" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        # Request header should override client header
        assert headers["authorization"] == "Bearer request-token"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"Authorization" => "Bearer client-token"}
        )

      assert {:ok, _response} =
               HTTPower.get(client, "/test",
                 headers: %{"Authorization" => "Bearer request-token"}
               )
    end

    test "request options override client options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          timeout: 30,
          max_retries: 3
        )

      # Request options should take precedence
      assert {:ok, _response} = HTTPower.get(client, "/test", timeout: 60, max_retries: 5)
    end
  end

  describe "3-arity POST: post(client, path, opts)" do
    test "makes POST request with client, path, and options" do
      HTTPower.Test.stub(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body == "name=John"
        HTTPower.Test.json(conn, %{created: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, response} = HTTPower.post(client, "/users", body: "name=John")
      assert response.status == 200
      assert response.body == %{"created" => true}
    end

    test "merges headers for POST requests" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        assert headers["x-api-key"] == "secret"
        assert headers["content-type"] == "application/json"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"X-API-Key" => "secret"}
        )

      assert {:ok, _} =
               HTTPower.post(client, "/data",
                 body: Jason.encode!(%{foo: "bar"}),
                 headers: %{"Content-Type" => "application/json"}
               )
    end
  end

  describe "3-arity PUT: put(client, path, opts)" do
    test "makes PUT request with client, path, and options" do
      HTTPower.Test.stub(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body == "name=Jane"
        HTTPower.Test.json(conn, %{updated: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, response} = HTTPower.put(client, "/users/1", body: "name=Jane")
      assert response.body == %{"updated" => true}
    end
  end

  describe "3-arity DELETE: delete(client, path, opts)" do
    test "makes DELETE request with client, path, and options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.text(conn, "", status: 204)
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, response} = HTTPower.delete(client, "/users/1", [])
      assert response.status == 204
    end

    test "passes custom headers with DELETE" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        assert headers["x-delete-reason"] == "spam"
        HTTPower.Test.text(conn, "", status: 204)
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, _} =
               HTTPower.delete(client, "/users/1", headers: %{"X-Delete-Reason" => "spam"})
    end
  end

  describe "URL building with various path formats" do
    test "builds URL with nil base_url" do
      HTTPower.Test.stub(fn conn ->
        # Should use full path as-is
        assert conn.request_path == "/users"
        HTTPower.Test.json(conn, %{success: true})
      end)

      # No base_url
      client = HTTPower.new()

      assert {:ok, _} = HTTPower.get(client, "https://api.example.com/users")
    end

    test "builds URL with empty path" do
      HTTPower.Test.stub(fn conn ->
        # Should just use base_url
        assert conn.host == "api.example.com"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, _} = HTTPower.get(client, "")
    end

    test "builds URL with leading slash in path" do
      HTTPower.Test.stub(fn conn ->
        assert conn.request_path == "/users"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, _} = HTTPower.get(client, "/users")
    end

    test "builds URL without leading slash in path" do
      HTTPower.Test.stub(fn conn ->
        assert conn.request_path == "/users"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      # Should add slash automatically
      assert {:ok, _} = HTTPower.get(client, "users")
    end

    test "builds URL with base_url ending in slash" do
      HTTPower.Test.stub(fn conn ->
        # Trailing slash in base_url is stripped before joining
        assert conn.request_path == "/users"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com/")

      assert {:ok, _} = HTTPower.get(client, "users")
    end

    test "builds URL without double slash when base_url has trailing slash" do
      HTTPower.Test.stub(fn conn ->
        assert conn.request_path == "/users"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com/")
      assert {:ok, _} = HTTPower.get(client, "/users")
    end

    test "builds URL with nested path" do
      HTTPower.Test.stub(fn conn ->
        assert conn.request_path == "/api/v1/users"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, _} = HTTPower.get(client, "/api/v1/users")
    end
  end

  describe "option merging logic" do
    test "merges all client options with request options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          timeout: 30,
          max_retries: 3,
          ssl_verify: false
        )

      # All options should be passed through
      assert {:ok, _} = HTTPower.get(client, "/test", retry_safe: true)
    end

    test "empty headers merge correctly" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      # Client with headers, request without
      client1 =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"X-Client" => "value"}
        )

      assert {:ok, _} = HTTPower.get(client1, "/test", [])

      # Client without headers, request with
      client2 = HTTPower.new(base_url: "https://api.example.com")
      assert {:ok, _} = HTTPower.get(client2, "/test", headers: %{"X-Request" => "value"})

      # Neither has headers
      client3 = HTTPower.new(base_url: "https://api.example.com")
      assert {:ok, _} = HTTPower.get(client3, "/test", [])
    end
  end
end

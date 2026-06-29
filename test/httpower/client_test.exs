defmodule HTTPower.ClientTest.OptsCapturingAdapter do
  @moduledoc false
  # Test adapter that records the opts it was handed, so we can assert which
  # options Client passes through to the adapter layer.
  @behaviour HTTPower.Adapter

  @impl true
  def request(_method, _url, _body, _headers, opts) do
    send(self(), {:adapter_opts, opts})
    {:ok, %HTTPower.Response{status: 200, headers: %{}, body: ""}}
  end
end

defmodule HTTPower.ClientTest do
  alias HTTPower.TelemetryTestHelper

  @moduledoc """
  Unit tests for HTTPower.Client module.

  These tests focus on improving coverage for:
  - Error message generation for various error types
  - Rate limit key extraction
  - Circuit breaker key extraction
  - Configuration helpers
  - Edge cases in retry logic
  """

  use ExUnit.Case, async: true
  alias HTTPower.Retry

  setup do
    HTTPower.Test.setup()
    :ok
  end

  describe "adapter option passing" do
    test "strips HTTPower-owned options but passes through unknown options" do
      HTTPower.get("https://api.example.com/x",
        adapter: HTTPower.ClientTest.OptsCapturingAdapter,
        circuit_breaker: [enabled: false],
        rate_limit: [enabled: false],
        deduplicate: false,
        max_retries: 0,
        base_delay: 1,
        custom_passthrough: 123
      )

      assert_received {:adapter_opts, opts}

      # HTTPower-owned options must not leak to the adapter / underlying client.
      refute Keyword.has_key?(opts, :circuit_breaker)
      refute Keyword.has_key?(opts, :rate_limit)
      refute Keyword.has_key?(opts, :deduplicate)
      refute Keyword.has_key?(opts, :max_retries)
      refute Keyword.has_key?(opts, :base_delay)

      # Unknown options pass straight through (e.g. adapter/Req-specific opts).
      assert Keyword.get(opts, :custom_passthrough) == 123
    end

    test "flags :block_redirects for the adapter when :block_private_ips is active" do
      HTTPower.get("https://api.example.com/x",
        adapter: HTTPower.ClientTest.OptsCapturingAdapter,
        block_private_ips: true,
        max_retries: 0,
        base_delay: 1
      )

      assert_received {:adapter_opts, opts}
      assert Keyword.get(opts, :block_redirects) == true
    end

    test "flags :block_redirects for the adapter when :allowed_hosts is active" do
      HTTPower.get("https://api.example.com/x",
        adapter: HTTPower.ClientTest.OptsCapturingAdapter,
        allowed_hosts: ["api.example.com"],
        max_retries: 0,
        base_delay: 1
      )

      assert_received {:adapter_opts, opts}
      assert Keyword.get(opts, :block_redirects) == true
    end

    test "does not flag :block_redirects when no SSRF guard is configured" do
      HTTPower.get("https://api.example.com/x",
        adapter: HTTPower.ClientTest.OptsCapturingAdapter,
        max_retries: 0,
        base_delay: 1
      )

      assert_received {:adapter_opts, opts}
      refute Keyword.has_key?(opts, :block_redirects)
    end

    test "with a {module, config} adapter, injects :adapter_config and passes through connection opts" do
      HTTPower.get("https://api.example.com/x",
        adapter: {HTTPower.ClientTest.OptsCapturingAdapter, [foo: :bar]},
        circuit_breaker: [enabled: false],
        rate_limit: [enabled: false],
        deduplicate: false,
        max_retries: 0,
        base_delay: 1,
        pool_timeout: 1000,
        custom_passthrough: 123
      )

      assert_received {:adapter_opts, opts}

      # The tuple's config is injected for the adapter to consume.
      assert Keyword.get(opts, :adapter_config) == [foo: :bar]

      # HTTPower-owned options are still stripped on the tuple path.
      refute Keyword.has_key?(opts, :circuit_breaker)
      refute Keyword.has_key?(opts, :max_retries)

      # Connection and unknown opts pass through (pool_timeout reaches the adapter).
      assert Keyword.get(opts, :pool_timeout) == 1000
      assert Keyword.get(opts, :custom_passthrough) == 123
    end
  end

  describe "retryable_error?/2" do
    test "returns true for timeout errors" do
      assert Retry.retryable_error?(:timeout, false) == true
      assert Retry.retryable_error?(:timeout, true) == true
    end

    test "returns true for closed connection" do
      assert Retry.retryable_error?(:closed, false) == true
      assert Retry.retryable_error?(:closed, true) == true
    end

    test "returns true for econnrefused" do
      assert Retry.retryable_error?(:econnrefused, false) == true
      assert Retry.retryable_error?(:econnrefused, true) == true
    end

    test "returns true for econnreset only when retry_safe is true" do
      assert Retry.retryable_error?(:econnreset, false) == false
      assert Retry.retryable_error?(:econnreset, true) == true
    end

    test "returns false for unknown error reasons" do
      assert Retry.retryable_error?(:unknown_error, false) == false
      assert Retry.retryable_error?(:unknown_error, true) == false
    end

    test "returns false for non-error values" do
      assert Retry.retryable_error?("not an error", false) == false
      assert Retry.retryable_error?(123, false) == false
      assert Retry.retryable_error?(%{}, false) == false
    end
  end

  describe "retryable_status?/1" do
    test "returns true for 408 Request Timeout" do
      assert Retry.retryable_status?(408) == true
    end

    test "returns true for 429 Too Many Requests" do
      assert Retry.retryable_status?(429) == true
    end

    test "returns true for 500 Internal Server Error" do
      assert Retry.retryable_status?(500) == true
    end

    test "returns true for 502 Bad Gateway" do
      assert Retry.retryable_status?(502) == true
    end

    test "returns true for 503 Service Unavailable" do
      assert Retry.retryable_status?(503) == true
    end

    test "returns true for 504 Gateway Timeout" do
      assert Retry.retryable_status?(504) == true
    end

    test "returns false for 2xx success codes" do
      assert Retry.retryable_status?(200) == false
      assert Retry.retryable_status?(201) == false
      assert Retry.retryable_status?(204) == false
    end

    test "returns false for 4xx client errors (except 408, 429)" do
      assert Retry.retryable_status?(400) == false
      assert Retry.retryable_status?(401) == false
      assert Retry.retryable_status?(403) == false
      assert Retry.retryable_status?(404) == false
    end
  end

  describe "calculate_backoff_delay/2" do
    test "calculates exponential backoff for first attempt" do
      retry_opts = %{
        base_delay: 1000,
        max_delay: 30_000,
        # No jitter for predictable testing
        jitter_factor: 0.0
      }

      # First attempt: 1000 * 2^0 = 1000ms
      delay = Retry.calculate_backoff_delay(1, retry_opts)
      assert delay == 1000
    end

    test "calculates exponential backoff for second attempt" do
      retry_opts = %{
        base_delay: 1000,
        max_delay: 30_000,
        jitter_factor: 0.0
      }

      # Second attempt: 1000 * 2^1 = 2000ms
      delay = Retry.calculate_backoff_delay(2, retry_opts)
      assert delay == 2000
    end

    test "calculates exponential backoff for third attempt" do
      retry_opts = %{
        base_delay: 1000,
        max_delay: 30_000,
        jitter_factor: 0.0
      }

      # Third attempt: 1000 * 2^2 = 4000ms
      delay = Retry.calculate_backoff_delay(3, retry_opts)
      assert delay == 4000
    end

    test "respects maximum delay cap" do
      retry_opts = %{
        base_delay: 1000,
        max_delay: 5000,
        jitter_factor: 0.0
      }

      # Would be 8000ms, but capped at 5000ms
      delay = Retry.calculate_backoff_delay(4, retry_opts)
      assert delay == 5000
    end

    test "applies jitter to prevent thundering herd" do
      retry_opts = %{
        base_delay: 1000,
        max_delay: 30_000,
        jitter_factor: 0.2
      }

      # With 20% jitter, delay should be between 800ms and 1000ms
      delay = Retry.calculate_backoff_delay(1, retry_opts)
      assert delay >= 800 and delay <= 1000
    end

    test "handles very large retry attempts" do
      retry_opts = %{
        base_delay: 1000,
        max_delay: 60_000,
        jitter_factor: 0.0
      }

      # Even with huge exponential growth, should be capped
      delay = Retry.calculate_backoff_delay(10, retry_opts)
      assert delay == 60_000
    end
  end

  describe "integration with rate limiting" do
    test "GET request respects rate limit configuration" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      # Request with rate limiting disabled
      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 rate_limit: [enabled: false]
               )
    end

    test "POST request respects rate limit configuration" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{created: true})
      end)

      assert {:ok, _response} =
               HTTPower.post("https://api.example.com/test",
                 body: "data",
                 rate_limit: [enabled: false]
               )
    end
  end

  describe "integration with circuit breaker" do
    test "GET request respects circuit breaker configuration" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      # Request with circuit breaker disabled
      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 circuit_breaker: [enabled: false]
               )
    end

    test "POST request respects circuit breaker configuration" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{created: true})
      end)

      assert {:ok, _response} =
               HTTPower.post("https://api.example.com/test",
                 body: "data",
                 circuit_breaker: [enabled: false]
               )
    end
  end

  describe "custom rate limit keys" do
    test "uses custom rate_limit_key when provided" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 rate_limit_key: "custom_key",
                 rate_limit: [enabled: false]
               )
    end
  end

  describe "custom circuit breaker keys" do
    test "uses custom circuit_breaker_key when provided" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 circuit_breaker_key: "custom_key",
                 circuit_breaker: [enabled: false]
               )
    end
  end

  describe "rate limit configuration variants" do
    test "handles rate_limit as boolean true" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 rate_limit: true
               )
    end

    test "handles rate_limit as boolean false" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 rate_limit: false
               )
    end

    test "handles rate_limit as keyword list" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 rate_limit: [max_tokens: 10, per: :second]
               )
    end
  end

  describe "circuit breaker configuration variants" do
    test "handles circuit_breaker as boolean true" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 circuit_breaker: true
               )
    end

    test "handles circuit_breaker as boolean false" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 circuit_breaker: false
               )
    end

    test "handles circuit_breaker as keyword list" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 circuit_breaker: [threshold: 5, timeout: 30_000]
               )
    end
  end

  describe "adapter configuration" do
    test "uses explicit adapter when provided" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 adapter: HTTPower.Adapter.Req
               )
    end

    test "uses adapter with config tuple" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      tesla_client = Tesla.client([])

      assert {:ok, _response} =
               HTTPower.get("https://api.example.com/test",
                 adapter: {HTTPower.Adapter.Tesla, tesla_client}
               )
    end
  end

  describe "URL parsing for rate limit and circuit breaker keys" do
    test "extracts host from URL for default keys" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      # Should extract "api.example.com" as the key
      assert {:ok, _response} = HTTPower.get("https://api.example.com/test")
    end

    test "rejects URLs without scheme (relative paths) with clear error" do
      # With fail-fast URL validation, relative paths are rejected early
      assert {:error, error} = HTTPower.get("/test")
      assert error.reason == :invalid_url
      assert error.message =~ "must use http or https scheme"
    end
  end

  describe "SSRF guardrails - block_private_ips" do
    test "blocks loopback IPv4 addresses" do
      assert {:error, error} =
               HTTPower.get("https://127.0.0.1/admin", block_private_ips: true)

      assert error.reason == :blocked_private_ip
    end

    test "blocks RFC1918 private addresses" do
      for host <- ["10.0.0.5", "172.16.0.1", "192.168.1.1"] do
        assert {:error, %{reason: :blocked_private_ip}} =
                 HTTPower.get("https://#{host}/x", block_private_ips: true)
      end
    end

    test "blocks the cloud metadata link-local address" do
      assert {:error, %{reason: :blocked_private_ip}} =
               HTTPower.get("https://169.254.169.254/latest/meta-data/",
                 block_private_ips: true
               )
    end

    test "blocks the localhost hostname" do
      assert {:error, %{reason: :blocked_private_ip}} =
               HTTPower.get("https://localhost/x", block_private_ips: true)
    end

    test "blocks IPv6 loopback" do
      assert {:error, %{reason: :blocked_private_ip}} =
               HTTPower.get("https://[::1]/x", block_private_ips: true)
    end

    test "blocks IPv6 link-local and unique-local addresses" do
      for host <- ["[fe80::1]", "[fc00::1]", "[fd12:3456::1]"] do
        assert {:error, %{reason: :blocked_private_ip}} =
                 HTTPower.get("https://#{host}/x", block_private_ips: true)
      end
    end

    test "allows a public IPv6 address even with block_private_ips enabled" do
      HTTPower.Test.stub(fn conn -> HTTPower.Test.json(conn, %{ok: true}) end)

      assert {:ok, %{status: 200}} =
               HTTPower.get("https://[2606:4700:4700::1111]/x", block_private_ips: true)
    end

    test "allows a public host even with block_private_ips enabled" do
      HTTPower.Test.stub(fn conn -> HTTPower.Test.json(conn, %{ok: true}) end)

      assert {:ok, %{status: 200}} =
               HTTPower.get("https://api.example.com/x", block_private_ips: true)
    end

    test "does not block private hosts when the guardrail is off (default)" do
      HTTPower.Test.stub(fn conn -> HTTPower.Test.json(conn, %{ok: true}) end)

      # No block_private_ips option: localhost is reachable (stub intercepts it).
      assert {:ok, %{status: 200}} = HTTPower.get("https://127.0.0.1/x")
    end
  end

  describe "SSRF guardrails - allowed_hosts" do
    test "rejects hosts not on the allowlist" do
      assert {:error, error} =
               HTTPower.get("https://evil.example.com/x",
                 allowed_hosts: ["api.example.com"]
               )

      assert error.reason == :host_not_allowed
    end

    test "allows hosts on the allowlist (case-insensitive)" do
      HTTPower.Test.stub(fn conn -> HTTPower.Test.json(conn, %{ok: true}) end)

      assert {:ok, %{status: 200}} =
               HTTPower.get("https://API.Example.com/x",
                 allowed_hosts: ["api.example.com"]
               )
    end
  end

  describe "telemetry - retry events" do
    setup do
      # Attach telemetry handler to capture events
      ref = make_ref()
      test_pid = self()

      events = [[:httpower, :retry, :attempt]]

      :telemetry.attach_many(
        ref,
        events,
        &TelemetryTestHelper.forward_event/4,
        %{test_pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(ref) end)

      %{ref: ref}
    end

    test "emits retry attempt events with delay and reason" do
      call_count = Agent.start_link(fn -> 0 end)
      {:ok, agent} = call_count

      HTTPower.Test.stub(fn conn ->
        count = Agent.get_and_update(agent, fn n -> {n, n + 1} end)

        if count < 2 do
          # Fail first two attempts
          Plug.Conn.resp(conn, 500, "Server Error")
        else
          # Succeed on third attempt
          HTTPower.Test.json(conn, %{recovered: true})
        end
      end)

      # Use unique host to filter telemetry events from concurrent tests
      test_host = "retry-telemetry-test-#{System.unique_integer([:positive])}.example.com"
      test_url = "https://#{test_host}/get"

      HTTPower.get(test_url,
        max_retries: 3,
        base_delay: 10,
        max_delay: 100
      )

      # Should see 2 retry events - filter by host to avoid cross-test interference
      # Note: URL in telemetry metadata is a %URI{} struct, so we match on host
      assert_received {:telemetry, [:httpower, :retry, :attempt], measurements,
                       %{url: %URI{host: ^test_host}} = metadata}

      assert measurements.attempt_number == 2
      # Jitter can reduce below base_delay
      assert measurements.delay_ms > 0
      assert metadata.method == :get
      assert metadata.reason == {:http_status, 500}

      assert_received {:telemetry, [:httpower, :retry, :attempt], measurements,
                       %{url: %URI{host: ^test_host}}}

      assert measurements.attempt_number == 3
      assert measurements.delay_ms > 0
    end
  end
end

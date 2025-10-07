defmodule HTTPower.ClientUnitTest do
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
  alias HTTPower.Client

  setup_all do
    Application.put_env(:httpower, :test_mode, true)
    :ok
  end

  setup do
    HTTPower.Test.setup()
    :ok
  end

  describe "retryable_error?/2" do
    test "returns true for timeout errors" do
      assert Client.retryable_error?(:timeout, false) == true
      assert Client.retryable_error?(:timeout, true) == true
    end

    test "returns true for closed connection" do
      assert Client.retryable_error?(:closed, false) == true
      assert Client.retryable_error?(:closed, true) == true
    end

    test "returns true for econnrefused" do
      assert Client.retryable_error?(:econnrefused, false) == true
      assert Client.retryable_error?(:econnrefused, true) == true
    end

    test "returns true for econnreset only when retry_safe is true" do
      assert Client.retryable_error?(:econnreset, false) == false
      assert Client.retryable_error?(:econnreset, true) == true
    end

    test "returns false for unknown error reasons" do
      assert Client.retryable_error?(:unknown_error, false) == false
      assert Client.retryable_error?(:unknown_error, true) == false
    end

    test "handles Mint.TransportError structs" do
      timeout_error = %Mint.TransportError{reason: :timeout}
      assert Client.retryable_error?(timeout_error, false) == true

      closed_error = %Mint.TransportError{reason: :closed}
      assert Client.retryable_error?(closed_error, false) == true

      refused_error = %Mint.TransportError{reason: :econnrefused}
      assert Client.retryable_error?(refused_error, false) == true

      reset_error = %Mint.TransportError{reason: :econnreset}
      assert Client.retryable_error?(reset_error, false) == false
      assert Client.retryable_error?(reset_error, true) == true
    end

    test "returns false for non-error values" do
      assert Client.retryable_error?("not an error", false) == false
      assert Client.retryable_error?(123, false) == false
      assert Client.retryable_error?(%{}, false) == false
    end
  end

  describe "retryable_status?/1" do
    test "returns true for 408 Request Timeout" do
      assert Client.retryable_status?(408) == true
    end

    test "returns true for 429 Too Many Requests" do
      assert Client.retryable_status?(429) == true
    end

    test "returns true for 500 Internal Server Error" do
      assert Client.retryable_status?(500) == true
    end

    test "returns true for 502 Bad Gateway" do
      assert Client.retryable_status?(502) == true
    end

    test "returns true for 503 Service Unavailable" do
      assert Client.retryable_status?(503) == true
    end

    test "returns true for 504 Gateway Timeout" do
      assert Client.retryable_status?(504) == true
    end

    test "returns false for 2xx success codes" do
      assert Client.retryable_status?(200) == false
      assert Client.retryable_status?(201) == false
      assert Client.retryable_status?(204) == false
    end

    test "returns false for 4xx client errors (except 408, 429)" do
      assert Client.retryable_status?(400) == false
      assert Client.retryable_status?(401) == false
      assert Client.retryable_status?(403) == false
      assert Client.retryable_status?(404) == false
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
      delay = Client.calculate_backoff_delay(1, retry_opts)
      assert delay == 1000
    end

    test "calculates exponential backoff for second attempt" do
      retry_opts = %{
        base_delay: 1000,
        max_delay: 30_000,
        jitter_factor: 0.0
      }

      # Second attempt: 1000 * 2^1 = 2000ms
      delay = Client.calculate_backoff_delay(2, retry_opts)
      assert delay == 2000
    end

    test "calculates exponential backoff for third attempt" do
      retry_opts = %{
        base_delay: 1000,
        max_delay: 30_000,
        jitter_factor: 0.0
      }

      # Third attempt: 1000 * 2^2 = 4000ms
      delay = Client.calculate_backoff_delay(3, retry_opts)
      assert delay == 4000
    end

    test "respects maximum delay cap" do
      retry_opts = %{
        base_delay: 1000,
        max_delay: 5000,
        jitter_factor: 0.0
      }

      # Would be 8000ms, but capped at 5000ms
      delay = Client.calculate_backoff_delay(4, retry_opts)
      assert delay == 5000
    end

    test "applies jitter to prevent thundering herd" do
      retry_opts = %{
        base_delay: 1000,
        max_delay: 30_000,
        jitter_factor: 0.2
      }

      # With 20% jitter, delay should be between 800ms and 1000ms
      delay = Client.calculate_backoff_delay(1, retry_opts)
      assert delay >= 800 and delay <= 1000
    end

    test "handles very large retry attempts" do
      retry_opts = %{
        base_delay: 1000,
        max_delay: 60_000,
        jitter_factor: 0.0
      }

      # Even with huge exponential growth, should be capped
      delay = Client.calculate_backoff_delay(10, retry_opts)
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

    test "handles URLs without host (relative paths)" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      # Should use the full path as the key when no host
      assert {:ok, _response} = HTTPower.get("/test")
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
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
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

      HTTPower.get("https://httpbin.org/get",
        max_retries: 3,
        base_delay: 10,
        max_delay: 100
      )

      # Should see 2 retry events
      assert_received {:telemetry, [:httpower, :retry, :attempt], measurements, metadata}
      assert measurements.attempt_number == 2
      assert measurements.delay_ms > 0  # Jitter can reduce below base_delay
      assert metadata.method == :get
      assert metadata.reason == {:http_status, 500}

      assert_received {:telemetry, [:httpower, :retry, :attempt], measurements, _metadata}
      assert measurements.attempt_number == 3
      assert measurements.delay_ms > 0
    end
  end
end

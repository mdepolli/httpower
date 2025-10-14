defmodule HTTPower.Middleware.RateLimiterTest do
  use ExUnit.Case, async: false

  alias HTTPower.Middleware.RateLimiter
  alias HTTPower.RateLimitHeaders

  setup do
    # Reset any existing buckets before each test
    :ets.delete_all_objects(:httpower_rate_limiter)

    # Ensure rate limiting is enabled for tests
    original_config = Application.get_env(:httpower, :rate_limit, [])

    on_exit(fn ->
      Application.put_env(:httpower, :rate_limit, original_config)
      :ets.delete_all_objects(:httpower_rate_limiter)
    end)

    :ok
  end

  describe "token bucket algorithm" do
    test "allows requests when tokens are available" do
      config = [enabled: true, requests: 10, per: :second]

      assert {:ok, remaining} = RateLimiter.check_rate_limit("test_bucket", config)
      assert remaining > 0.0
    end

    test "blocks requests when tokens are exhausted" do
      config = [enabled: true, requests: 2, per: :second]

      # Consume all tokens
      assert :ok = RateLimiter.consume("test_bucket", config)
      assert :ok = RateLimiter.consume("test_bucket", config)

      # Next check should fail
      assert {:error, :too_many_requests, wait_time} =
               RateLimiter.check_rate_limit("test_bucket", config)

      assert wait_time > 0
    end

    test "refills tokens over time" do
      # 100 requests per second = 1 token every 10ms
      config = [enabled: true, requests: 100, per: :second]

      # Consume a token
      assert :ok = RateLimiter.consume("test_bucket", config)

      # Wait for refill (20ms should give us at least 1 token back)
      :timer.sleep(20)

      # Should have tokens again
      assert {:ok, remaining} = RateLimiter.check_rate_limit("test_bucket", config)
      assert remaining >= 1.0
    end

    test "respects maximum token capacity" do
      config = [enabled: true, requests: 5, per: :second]

      # Wait to ensure bucket is full
      :timer.sleep(100)

      # Check multiple times - shouldn't exceed max
      assert {:ok, remaining} = RateLimiter.check_rate_limit("test_bucket", config)
      assert remaining <= 5.0
    end
  end

  describe "configuration" do
    test "respects global configuration" do
      Application.put_env(:httpower, :rate_limit,
        enabled: true,
        requests: 3,
        per: :second
      )

      # Restart GenServer to pick up new config (config is cached at startup)
      GenServer.stop(RateLimiter)
      # Wait for supervisor to restart
      Process.sleep(50)

      # Should use global config
      assert :ok = RateLimiter.consume("test_bucket")
      assert :ok = RateLimiter.consume("test_bucket")
      assert :ok = RateLimiter.consume("test_bucket")

      # Next one should be rate limited
      assert {:error, :too_many_requests, _} =
               RateLimiter.check_rate_limit("test_bucket")
    end

    test "per-request config overrides global config" do
      Application.put_env(:httpower, :rate_limit,
        enabled: true,
        requests: 100,
        per: :second
      )

      # Override with stricter limit
      config = [enabled: true, requests: 2, per: :second]

      assert :ok = RateLimiter.consume("test_bucket", config)
      assert :ok = RateLimiter.consume("test_bucket", config)

      # Should hit the per-request limit, not global
      assert {:error, :too_many_requests, _} =
               RateLimiter.check_rate_limit("test_bucket", config)
    end

    test "supports different time windows" do
      # Per second
      config_second = [enabled: true, requests: 10, per: :second]
      assert {:ok, _} = RateLimiter.check_rate_limit("bucket_second", config_second)

      # Per minute
      config_minute = [enabled: true, requests: 100, per: :minute]
      assert {:ok, _} = RateLimiter.check_rate_limit("bucket_minute", config_minute)

      # Per hour
      config_hour = [enabled: true, requests: 1000, per: :hour]
      assert {:ok, _} = RateLimiter.check_rate_limit("bucket_hour", config_hour)
    end

    test "rate limiting disabled by default" do
      # No global config
      Application.delete_env(:httpower, :rate_limit)

      assert {:ok, :disabled} = RateLimiter.check_rate_limit("test_bucket")
      assert :ok = RateLimiter.consume("test_bucket")
    end

    test "can explicitly disable rate limiting" do
      config = [enabled: false]

      assert {:ok, :disabled} = RateLimiter.check_rate_limit("test_bucket", config)
      assert :ok = RateLimiter.consume("test_bucket", config)
    end
  end

  describe "strategies" do
    test ":error strategy returns error immediately" do
      config = [enabled: true, requests: 1, per: :second, strategy: :error]

      # First request succeeds
      assert :ok = RateLimiter.consume("test_bucket", config)

      # Second request fails immediately
      assert {:error, :too_many_requests} = RateLimiter.consume("test_bucket", config)
    end

    test ":wait strategy waits for tokens" do
      config = [enabled: true, requests: 10, per: :second, strategy: :wait]

      # Consume all tokens
      for _ <- 1..10 do
        assert :ok = RateLimiter.consume("test_bucket", config)
      end

      # Next request should wait (and succeed after brief wait)
      start_time = System.monotonic_time(:millisecond)
      assert :ok = RateLimiter.consume("test_bucket", config)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should have waited at least a few milliseconds
      assert elapsed > 50
    end

    test ":wait strategy respects max_wait_time" do
      config = [
        enabled: true,
        requests: 1,
        per: :hour,
        # Need to wait a very long time
        strategy: :wait,
        max_wait_time: 10
        # Only wait 10ms max
      ]

      # Consume the only token
      assert :ok = RateLimiter.consume("test_bucket", config)

      # Next request should timeout
      assert {:error, :rate_limit_wait_timeout} = RateLimiter.consume("test_bucket", config)
    end
  end

  describe "bucket isolation" do
    test "different buckets have independent limits" do
      config = [enabled: true, requests: 2, per: :second]

      # Exhaust bucket 1
      assert :ok = RateLimiter.consume("bucket_1", config)
      assert :ok = RateLimiter.consume("bucket_1", config)
      assert {:error, :too_many_requests, _} = RateLimiter.check_rate_limit("bucket_1", config)

      # Bucket 2 should still have tokens
      assert {:ok, _} = RateLimiter.check_rate_limit("bucket_2", config)
      assert :ok = RateLimiter.consume("bucket_2", config)
    end

    test "same bucket key shares limits across calls" do
      config = [enabled: true, requests: 3, per: :second]
      key = "shared_bucket"

      # Consume from different places with same key
      assert :ok = RateLimiter.consume(key, config)
      assert :ok = RateLimiter.consume(key, config)
      assert :ok = RateLimiter.consume(key, config)

      # Should hit limit
      assert {:error, :too_many_requests, _} = RateLimiter.check_rate_limit(key, config)
    end
  end

  describe "bucket management" do
    test "can reset a bucket" do
      config = [enabled: true, requests: 2, per: :second]

      # Exhaust tokens
      assert :ok = RateLimiter.consume("test_bucket", config)
      assert :ok = RateLimiter.consume("test_bucket", config)

      assert {:error, :too_many_requests, _} =
               RateLimiter.check_rate_limit("test_bucket", config)

      # Reset bucket
      assert :ok = RateLimiter.reset_bucket("test_bucket")

      # Should have tokens again
      assert {:ok, _} = RateLimiter.check_rate_limit("test_bucket", config)
    end

    test "get_bucket_state returns current state" do
      config = [enabled: true, requests: 10, per: :second]

      # Create a bucket
      assert :ok = RateLimiter.consume("test_bucket", config)

      # Should have state
      state = RateLimiter.get_bucket_state("test_bucket")
      assert {tokens, timestamp} = state
      assert is_float(tokens)
      assert is_integer(timestamp)
    end

    test "get_bucket_state returns nil for non-existent bucket" do
      assert nil == RateLimiter.get_bucket_state("non_existent")
    end
  end

  describe "integration scenarios" do
    test "realistic API rate limit scenario" do
      # Simulate GitHub API: 60 requests per minute
      config = [enabled: true, requests: 60, per: :minute, strategy: :wait]

      # Make 60 requests quickly
      for _ <- 1..60 do
        assert :ok = RateLimiter.consume("github_api", config)
      end

      # 61st request should wait
      start_time = System.monotonic_time(:millisecond)
      assert :ok = RateLimiter.consume("github_api", config)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should have waited at least 1 second (1000ms)
      assert elapsed >= 900
    end

    test "burst handling with token bucket" do
      # Allow 10 requests per second with burst capability
      config = [enabled: true, requests: 10, per: :second]

      # Burst: make 10 requests immediately
      for _ <- 1..10 do
        assert :ok = RateLimiter.consume("burst_api", config)
      end

      # Next request should be rate limited
      assert {:error, :too_many_requests, _} =
               RateLimiter.check_rate_limit("burst_api", config)

      # Wait for refill (200ms = 2 tokens at 10 per second)
      :timer.sleep(200)

      # Should be able to make 2 more requests
      assert :ok = RateLimiter.consume("burst_api", config)
      assert :ok = RateLimiter.consume("burst_api", config)
    end

    test "per-endpoint rate limiting" do
      # Different endpoints have different limits
      search_config = [enabled: true, requests: 10, per: :minute, strategy: :error]
      api_config = [enabled: true, requests: 100, per: :minute, strategy: :error]

      # Exhaust search endpoint
      for _ <- 1..10 do
        assert :ok = RateLimiter.consume("api.example.com/search", search_config)
      end

      assert {:error, :too_many_requests} =
               RateLimiter.consume("api.example.com/search", search_config)

      # API endpoint should still work
      assert :ok = RateLimiter.consume("api.example.com/users", api_config)
    end
  end

  describe "edge cases" do
    test "handles very high request rates" do
      config = [enabled: true, requests: 1000, per: :second]

      # Should handle many sequential checks
      for _ <- 1..100 do
        assert {:ok, _} = RateLimiter.check_rate_limit("high_rate", config)
      end
    end

    test "handles very low request rates" do
      config = [enabled: true, requests: 1, per: :hour]

      assert :ok = RateLimiter.consume("low_rate", config)

      # Second request should be heavily rate limited
      assert {:error, :too_many_requests, wait_time} =
               RateLimiter.check_rate_limit("low_rate", config)

      # Wait time should be close to 1 hour (3600000ms)
      assert wait_time > 3_000_000
    end

    test "handles concurrent access to same bucket" do
      config = [enabled: true, requests: 20, per: :second]

      # Spawn multiple processes consuming from same bucket
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            RateLimiter.consume("concurrent_bucket", config)
          end)
        end

      results = Task.await_many(tasks)

      # All should succeed (we have exactly 20 tokens)
      assert Enum.all?(results, &(&1 == :ok))

      # Next request should fail
      assert {:error, :too_many_requests, _} =
               RateLimiter.check_rate_limit("concurrent_bucket", config)
    end
  end

  describe "rate limit header integration" do
    test "update_from_headers synchronizes bucket with server state" do
      config = [enabled: true, requests: 100, per: :minute]

      # Initial state - bucket has full capacity
      assert {:ok, remaining} = RateLimiter.check_rate_limit("github_api", config)
      assert remaining == 100.0

      # Simulate receiving rate limit headers from GitHub API
      rate_limit_info = %{
        limit: 60,
        remaining: 55,
        reset_at: ~U[2025-10-01 12:00:00Z],
        format: :github
      }

      # Update bucket from server headers
      assert :ok = RateLimiter.update_from_headers("github_api", rate_limit_info)

      # Bucket should now reflect server state (55 tokens remaining)
      {current_tokens, _last_refill_ms} = RateLimiter.get_bucket_state("github_api")
      assert current_tokens == 55.0
    end

    test "get_info returns current bucket information" do
      config = [enabled: true, requests: 100, per: :minute]

      # Create bucket
      assert :ok = RateLimiter.consume("api_bucket", config)

      # Get info
      info = RateLimiter.get_info("api_bucket")
      assert info != nil
      assert Map.has_key?(info, :current_tokens)
      assert Map.has_key?(info, :last_refill_ms)
      assert info.current_tokens < 100.0
    end

    test "get_info returns nil for non-existent bucket" do
      assert nil == RateLimiter.get_info("non_existent_bucket")
    end

    test "update_from_headers works with various header formats" do
      # Test with RFC format headers
      rfc_info = %{
        limit: 100,
        remaining: 80,
        reset_at: ~U[2025-10-01 13:00:00Z],
        format: :rfc
      }

      assert :ok = RateLimiter.update_from_headers("rfc_api", rfc_info)
      {tokens, _} = RateLimiter.get_bucket_state("rfc_api")
      assert tokens == 80.0

      # Test with Stripe format headers
      stripe_info = %{
        limit: 100,
        remaining: 95,
        reset_at: ~U[2025-10-01 14:00:00Z],
        format: :stripe
      }

      assert :ok = RateLimiter.update_from_headers("stripe_api", stripe_info)
      {tokens, _} = RateLimiter.get_bucket_state("stripe_api")
      assert tokens == 95.0
    end

    test "update_from_headers handles zero remaining tokens" do
      rate_limit_info = %{
        limit: 60,
        remaining: 0,
        reset_at: ~U[2025-10-01 12:00:00Z],
        format: :github
      }

      assert :ok = RateLimiter.update_from_headers("exhausted_api", rate_limit_info)
      {tokens, _} = RateLimiter.get_bucket_state("exhausted_api")
      assert tokens == 0.0
    end

    test "integration: parse headers and update bucket" do
      # Simulate receiving HTTP response headers from GitHub
      headers = %{
        "x-ratelimit-limit" => "60",
        "x-ratelimit-remaining" => "42",
        "x-ratelimit-reset" => "1234567890"
      }

      # Parse headers
      assert {:ok, rate_limit_info} = RateLimitHeaders.parse(headers)
      assert rate_limit_info.remaining == 42

      # Update bucket from parsed headers
      assert :ok = RateLimiter.update_from_headers("github_integration", rate_limit_info)

      # Verify bucket state matches server
      {tokens, _} = RateLimiter.get_bucket_state("github_integration")
      assert tokens == 42.0

      # Get info should show the synchronized state
      info = RateLimiter.get_info("github_integration")
      assert info.current_tokens == 42.0
    end

    test "bucket continues to refill after server synchronization" do
      config = [enabled: true, requests: 100, per: :second]

      # Synchronize with server state (10 tokens remaining)
      rate_limit_info = %{
        limit: 100,
        remaining: 10,
        reset_at: ~U[2025-10-01 12:00:00Z],
        format: :github
      }

      assert :ok = RateLimiter.update_from_headers("refill_test", rate_limit_info)

      # Verify starting state
      {tokens_before, _} = RateLimiter.get_bucket_state("refill_test")
      assert tokens_before == 10.0

      # Wait for token refill (100 req/sec = 10 tokens per 100ms)
      :timer.sleep(150)

      # Check that bucket has refilled
      assert {:ok, remaining} = RateLimiter.check_rate_limit("refill_test", config)
      assert remaining > 10.0
    end
  end

  describe "crash recovery" do
    test "GenServer crash doesn't orphan ETS table" do
      config = [enabled: true, requests: 10, per: :minute]

      # Use rate limiter
      assert :ok = RateLimiter.consume("crash_test", config)

      # Get GenServer pid and kill it
      pid = Process.whereis(HTTPower.Middleware.RateLimiter)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      # Wait for process to die
      receive do
        {:DOWN, ^ref, :process, ^pid, :killed} -> :ok
      after
        1_000 -> flunk("GenServer didn't die")
      end

      # Wait for supervisor to restart
      :timer.sleep(100)

      # Should be able to use rate limiter again (new ETS table created)
      assert :ok = RateLimiter.consume("crash_test", config)

      # New GenServer should be running
      new_pid = Process.whereis(HTTPower.Middleware.RateLimiter)
      assert new_pid != nil
      assert new_pid != pid
    end
  end

  describe "telemetry - rate limiter events" do
    setup do
      # Reset rate limiter state
      RateLimiter.reset_bucket("test_bucket")

      # Attach telemetry handler to capture events
      ref = make_ref()
      test_pid = self()

      events = [
        [:httpower, :rate_limit, :ok],
        [:httpower, :rate_limit, :wait],
        [:httpower, :rate_limit, :exceeded]
      ]

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

    test "emits ok event when rate limit is not exceeded" do
      config = [enabled: true, requests: 10, per: :second]

      RateLimiter.consume("test_bucket", config)

      assert_received {:telemetry, [:httpower, :rate_limit, :ok], measurements, metadata}
      assert measurements.tokens_remaining > 0
      assert measurements.wait_time_ms == 0
      assert metadata.bucket_key == "test_bucket"
    end

    test "emits wait event when rate limit exceeded with wait strategy" do
      config = [enabled: true, requests: 5, per: :second, strategy: :wait, max_wait_time: 500]

      # Exhaust the rate limit
      for _ <- 1..5 do
        RateLimiter.consume("test_bucket", config)
      end

      # Clear previous telemetry messages
      flush_telemetry()

      # This should trigger wait
      RateLimiter.consume("test_bucket", config)

      assert_received {:telemetry, [:httpower, :rate_limit, :wait], measurements, metadata}
      assert measurements.wait_time_ms > 0
      assert metadata.bucket_key == "test_bucket"
      assert metadata.strategy == :wait
    end

    test "emits exceeded event when rate limit exceeded with error strategy" do
      config = [enabled: true, requests: 5, per: :second, strategy: :error]

      # Exhaust the rate limit
      for _ <- 1..5 do
        RateLimiter.consume("test_bucket", config)
      end

      # Clear previous telemetry messages
      flush_telemetry()

      # This should trigger error
      {:error, :too_many_requests} = RateLimiter.consume("test_bucket", config)

      assert_received {:telemetry, [:httpower, :rate_limit, :exceeded], measurements, metadata}
      assert measurements.tokens_remaining == 0
      assert metadata.bucket_key == "test_bucket"
      assert metadata.strategy == :error
    end
  end

  defp flush_telemetry do
    receive do
      {:telemetry, _, _, _} -> flush_telemetry()
    after
      0 -> :ok
    end
  end
end

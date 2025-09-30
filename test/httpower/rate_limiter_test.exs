defmodule HTTPower.RateLimiterTest do
  use ExUnit.Case, async: false

  alias HTTPower.RateLimiter

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
      assert {:error, :rate_limit_exceeded, wait_time} =
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

      # Should use global config
      assert :ok = RateLimiter.consume("test_bucket")
      assert :ok = RateLimiter.consume("test_bucket")
      assert :ok = RateLimiter.consume("test_bucket")

      # Next one should be rate limited
      assert {:error, :rate_limit_exceeded, _} =
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
      assert {:error, :rate_limit_exceeded, _} =
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
      assert {:error, :rate_limit_exceeded} = RateLimiter.consume("test_bucket", config)
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
      assert {:error, :rate_limit_exceeded, _} = RateLimiter.check_rate_limit("bucket_1", config)

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
      assert {:error, :rate_limit_exceeded, _} = RateLimiter.check_rate_limit(key, config)
    end
  end

  describe "bucket management" do
    test "can reset a bucket" do
      config = [enabled: true, requests: 2, per: :second]

      # Exhaust tokens
      assert :ok = RateLimiter.consume("test_bucket", config)
      assert :ok = RateLimiter.consume("test_bucket", config)

      assert {:error, :rate_limit_exceeded, _} =
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
      assert {:error, :rate_limit_exceeded, _} =
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

      assert {:error, :rate_limit_exceeded} =
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
      assert {:error, :rate_limit_exceeded, wait_time} =
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
      assert {:error, :rate_limit_exceeded, _} =
               RateLimiter.check_rate_limit("concurrent_bucket", config)
    end
  end
end

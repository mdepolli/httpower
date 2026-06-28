defmodule HTTPower.Middleware.RateLimiterTest do
  use ExUnit.Case, async: true

  import HTTPower.Test.Keys
  alias HTTPower.Middleware.RateLimiter
  alias HTTPower.RateLimitHeaders

  setup do
    {:ok, bucket_key: uniq("rl")}
  end

  describe "token bucket algorithm" do
    test "allows requests when tokens are available", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 10, per: :second]

      assert {:ok, remaining} = RateLimiter.check_rate_limit(bucket_key, config)
      assert remaining > 0.0
    end

    test "blocks requests when tokens are exhausted", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 2, per: :second]

      # Consume all tokens
      assert :ok = RateLimiter.consume(bucket_key, config)
      assert :ok = RateLimiter.consume(bucket_key, config)

      # Next check should fail
      assert {:error, :too_many_requests, wait_time} =
               RateLimiter.check_rate_limit(bucket_key, config)

      assert wait_time > 0
    end

    test "refills tokens over time", %{bucket_key: bucket_key} do
      # 100 requests per second = 1 token every 10ms
      config = [enabled: true, requests: 100, per: :second]

      # Consume a token
      assert :ok = RateLimiter.consume(bucket_key, config)

      # Wait for refill (20ms should give us at least 1 token back)
      :timer.sleep(20)

      # Should have tokens again
      assert {:ok, remaining} = RateLimiter.check_rate_limit(bucket_key, config)
      assert remaining >= 1.0
    end

    test "respects maximum token capacity", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 5, per: :second]

      # Wait to ensure bucket is full
      :timer.sleep(100)

      # Check multiple times - shouldn't exceed max
      assert {:ok, remaining} = RateLimiter.check_rate_limit(bucket_key, config)
      assert remaining <= 5.0
    end
  end

  describe "configuration" do
    test "supports different time windows", %{bucket_key: bucket_key} do
      # Per second
      config_second = [enabled: true, requests: 10, per: :second]
      assert {:ok, _} = RateLimiter.check_rate_limit(bucket_key, config_second)

      # Per minute
      config_minute = [enabled: true, requests: 100, per: :minute]
      assert {:ok, _} = RateLimiter.check_rate_limit(uniq("rl"), config_minute)

      # Per hour
      config_hour = [enabled: true, requests: 1000, per: :hour]
      assert {:ok, _} = RateLimiter.check_rate_limit(uniq("rl"), config_hour)
    end

    test "can explicitly disable rate limiting", %{bucket_key: bucket_key} do
      config = [enabled: false]

      assert {:ok, :disabled} = RateLimiter.check_rate_limit(bucket_key, config)
      assert :ok = RateLimiter.consume(bucket_key, config)
    end
  end

  describe "strategies" do
    test ":error strategy returns error immediately", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 1, per: :second, strategy: :error]

      # First request succeeds
      assert :ok = RateLimiter.consume(bucket_key, config)

      # Second request fails immediately
      assert {:error, :too_many_requests} = RateLimiter.consume(bucket_key, config)
    end

    test ":wait strategy waits for tokens", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 10, per: :second, strategy: :wait]

      # Consume all tokens
      for _ <- 1..10 do
        assert :ok = RateLimiter.consume(bucket_key, config)
      end

      # Next request should wait (and succeed after brief wait)
      start_time = System.monotonic_time(:millisecond)
      assert :ok = RateLimiter.consume(bucket_key, config)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should have waited at least a few milliseconds
      assert elapsed > 50
    end

    test ":wait strategy respects max_wait_time", %{bucket_key: bucket_key} do
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
      assert :ok = RateLimiter.consume(bucket_key, config)

      # Next request should timeout
      assert {:error, :rate_limit_wait_timeout} = RateLimiter.consume(bucket_key, config)
    end
  end

  describe "bucket isolation" do
    test "different buckets have independent limits", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 2, per: :second]
      other_bucket = uniq("rl")

      # Exhaust bucket 1
      assert :ok = RateLimiter.consume(bucket_key, config)
      assert :ok = RateLimiter.consume(bucket_key, config)
      assert {:error, :too_many_requests, _} = RateLimiter.check_rate_limit(bucket_key, config)

      # Bucket 2 should still have tokens
      assert {:ok, _} = RateLimiter.check_rate_limit(other_bucket, config)
      assert :ok = RateLimiter.consume(other_bucket, config)
    end

    test "same bucket key shares limits across calls", %{bucket_key: key} do
      config = [enabled: true, requests: 3, per: :second]

      # Consume from different places with same key
      assert :ok = RateLimiter.consume(key, config)
      assert :ok = RateLimiter.consume(key, config)
      assert :ok = RateLimiter.consume(key, config)

      # Should hit limit
      assert {:error, :too_many_requests, _} = RateLimiter.check_rate_limit(key, config)
    end
  end

  describe "bucket management" do
    test "can reset a bucket", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 2, per: :second]

      # Exhaust tokens
      assert :ok = RateLimiter.consume(bucket_key, config)
      assert :ok = RateLimiter.consume(bucket_key, config)

      assert {:error, :too_many_requests, _} =
               RateLimiter.check_rate_limit(bucket_key, config)

      # Reset bucket
      assert :ok = RateLimiter.reset_bucket(bucket_key)

      # Should have tokens again
      assert {:ok, _} = RateLimiter.check_rate_limit(bucket_key, config)
    end

    test "get_bucket_state returns current state", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 10, per: :second]

      # Create a bucket
      assert :ok = RateLimiter.consume(bucket_key, config)

      # Should have state — the raw GCRA tat (monotonic microseconds)
      state = RateLimiter.get_bucket_state(bucket_key)
      assert is_integer(state)
    end

    test "get_bucket_state returns nil for non-existent bucket", %{bucket_key: bucket_key} do
      assert nil == RateLimiter.get_bucket_state(bucket_key)
    end
  end

  describe "integration scenarios" do
    test "realistic API rate limit scenario", %{bucket_key: bucket_key} do
      # Simulate GitHub API: 60 requests per minute
      config = [enabled: true, requests: 60, per: :minute, strategy: :wait]

      # Make 60 requests quickly
      for _ <- 1..60 do
        assert :ok = RateLimiter.consume(bucket_key, config)
      end

      # 61st request should wait
      start_time = System.monotonic_time(:millisecond)
      assert :ok = RateLimiter.consume(bucket_key, config)
      elapsed = System.monotonic_time(:millisecond) - start_time

      # Should have waited at least 1 second (1000ms)
      assert elapsed >= 900
    end

    test "burst handling with token bucket", %{bucket_key: bucket_key} do
      # Allow 10 requests per second with burst capability
      config = [enabled: true, requests: 10, per: :second]

      # Burst: make 10 requests immediately
      for _ <- 1..10 do
        assert :ok = RateLimiter.consume(bucket_key, config)
      end

      # Next request should be rate limited
      assert {:error, :too_many_requests, _} =
               RateLimiter.check_rate_limit(bucket_key, config)

      # Wait for refill (200ms = 2 tokens at 10 per second)
      :timer.sleep(200)

      # Should be able to make 2 more requests
      assert :ok = RateLimiter.consume(bucket_key, config)
      assert :ok = RateLimiter.consume(bucket_key, config)
    end

    test "per-endpoint rate limiting", %{bucket_key: bucket_key} do
      # Different endpoints have different limits
      search_config = [enabled: true, requests: 10, per: :minute, strategy: :error]
      api_config = [enabled: true, requests: 100, per: :minute, strategy: :error]
      api_bucket = uniq("rl")

      # Exhaust search endpoint
      for _ <- 1..10 do
        assert :ok = RateLimiter.consume(bucket_key, search_config)
      end

      assert {:error, :too_many_requests} =
               RateLimiter.consume(bucket_key, search_config)

      # API endpoint should still work
      assert :ok = RateLimiter.consume(api_bucket, api_config)
    end
  end

  describe "lock-free consume" do
    test "under concurrency, never admits more than the bucket capacity" do
      # per: :hour makes refill during the (sub-second) test negligible, so a
      # capacity-50 bucket must admit exactly 50 of 200 concurrent consumers —
      # no over-admission from a lost-update race.
      config = [enabled: true, requests: 50, per: :hour, strategy: :error]
      key = "race_#{System.unique_integer([:positive])}"

      results =
        1..200
        |> Task.async_stream(fn _ -> RateLimiter.consume(key, config) end,
          max_concurrency: 50,
          ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &(&1 == :ok)) == 50
    end
  end

  describe "edge cases" do
    test "handles very high request rates", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 1000, per: :second]

      # Should handle many sequential checks
      for _ <- 1..100 do
        assert {:ok, _} = RateLimiter.check_rate_limit(bucket_key, config)
      end
    end

    test "handles very low request rates", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 1, per: :hour]

      assert :ok = RateLimiter.consume(bucket_key, config)

      # Second request should be heavily rate limited
      assert {:error, :too_many_requests, wait_time} =
               RateLimiter.check_rate_limit(bucket_key, config)

      # Wait time should be close to 1 hour (3600000ms)
      assert wait_time > 3_000_000
    end

    test "handles concurrent access to same bucket", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 20, per: :second]

      # Spawn multiple processes consuming from same bucket
      tasks =
        for _ <- 1..20 do
          Task.async(fn ->
            RateLimiter.consume(bucket_key, config)
          end)
        end

      results = Task.await_many(tasks)

      # All should succeed (we have exactly 20 tokens)
      assert Enum.all?(results, &(&1 == :ok))

      # Next request should fail
      assert {:error, :too_many_requests, _} =
               RateLimiter.check_rate_limit(bucket_key, config)
    end
  end

  describe "rate limit header integration" do
    test "update_from_headers synchronizes bucket with server state", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 100, per: :minute]

      # Initial state - bucket has full capacity
      assert {:ok, 100.0} = RateLimiter.check_rate_limit(bucket_key, config)

      # Simulate receiving rate limit headers from GitHub API
      rate_limit_info = %{
        limit: 60,
        remaining: 55,
        reset_at: ~U[2025-10-01 12:00:00Z],
        format: :github
      }

      # Update bucket from server headers
      assert :ok = RateLimiter.update_from_headers(bucket_key, rate_limit_info, config)

      # Bucket should now reflect server state (~55 tokens remaining)
      assert {:ok, remaining} = RateLimiter.check_rate_limit(bucket_key, config)
      assert_in_delta remaining, 55.0, 1.0
    end

    test "get_info returns current bucket information", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 100, per: :minute]

      # Create bucket
      assert :ok = RateLimiter.consume(bucket_key, config)

      # Get info — exposes the raw GCRA tat
      info = RateLimiter.get_info(bucket_key)
      assert info != nil
      assert is_integer(info.tat_us)
    end

    test "get_info returns nil for non-existent bucket", %{bucket_key: bucket_key} do
      assert nil == RateLimiter.get_info(bucket_key)
    end

    test "update_from_headers works with various header formats", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 100, per: :minute]

      # Test with RFC format headers
      rfc_info = %{
        limit: 100,
        remaining: 80,
        reset_at: ~U[2025-10-01 13:00:00Z],
        format: :rfc
      }

      assert :ok = RateLimiter.update_from_headers(bucket_key, rfc_info, config)
      assert {:ok, rfc_remaining} = RateLimiter.check_rate_limit(bucket_key, config)
      assert_in_delta rfc_remaining, 80.0, 1.0

      # Test with Stripe format headers
      stripe_bucket = uniq("rl")

      stripe_info = %{
        limit: 100,
        remaining: 95,
        reset_at: ~U[2025-10-01 14:00:00Z],
        format: :stripe
      }

      assert :ok = RateLimiter.update_from_headers(stripe_bucket, stripe_info, config)
      assert {:ok, stripe_remaining} = RateLimiter.check_rate_limit(stripe_bucket, config)
      assert_in_delta stripe_remaining, 95.0, 1.0
    end

    test "update_from_headers handles zero remaining tokens", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 60, per: :minute]

      rate_limit_info = %{
        limit: 60,
        remaining: 0,
        reset_at: ~U[2025-10-01 12:00:00Z],
        format: :github
      }

      assert :ok = RateLimiter.update_from_headers(bucket_key, rate_limit_info, config)

      # No tokens left — the next request is rate limited
      assert {:error, :too_many_requests, _wait} =
               RateLimiter.check_rate_limit(bucket_key, config)
    end

    test "integration: parse headers and update bucket", %{bucket_key: bucket_key} do
      # Simulate receiving HTTP response headers from GitHub
      headers = %{
        "x-ratelimit-limit" => "60",
        "x-ratelimit-remaining" => "42",
        "x-ratelimit-reset" => "1234567890"
      }

      config = [enabled: true, requests: 100, per: :minute]

      # Parse headers
      assert {:ok, rate_limit_info} = RateLimitHeaders.parse(headers)
      assert rate_limit_info.remaining == 42

      # Update bucket from parsed headers
      assert :ok = RateLimiter.update_from_headers(bucket_key, rate_limit_info, config)

      # Verify bucket reflects server state (~42 tokens remaining)
      assert {:ok, remaining} = RateLimiter.check_rate_limit(bucket_key, config)
      assert_in_delta remaining, 42.0, 1.0

      # Get info should expose the synchronized GCRA state
      assert is_integer(RateLimiter.get_info(bucket_key).tat_us)
    end

    test "bucket continues to refill after server synchronization", %{bucket_key: bucket_key} do
      config = [enabled: true, requests: 100, per: :second]

      # Synchronize with server state (10 tokens remaining)
      rate_limit_info = %{
        limit: 100,
        remaining: 10,
        reset_at: ~U[2025-10-01 12:00:00Z],
        format: :github
      }

      assert :ok = RateLimiter.update_from_headers(bucket_key, rate_limit_info, config)

      # Verify starting state (~10 tokens remaining)
      assert {:ok, before} = RateLimiter.check_rate_limit(bucket_key, config)
      assert_in_delta before, 10.0, 1.0

      # Wait for token refill (100 req/sec = 10 tokens per 100ms)
      :timer.sleep(150)

      # Check that bucket has refilled
      assert {:ok, remaining} = RateLimiter.check_rate_limit(bucket_key, config)
      assert remaining > 10.0
    end
  end
end

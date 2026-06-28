defmodule HTTPower.Middleware.RateLimiterGlobalTest do
  # async: false — these tests mutate global :rate_limit config, manipulate the
  # shared RateLimiter GenServer's lifecycle (GenServer.stop, Process.exit,
  # :sys.suspend), trigger a keyless global operation (send :cleanup), or attach
  # global telemetry handlers that would receive events from other concurrently-
  # running tests. They keep the original global-wipe setup and run serially.
  use ExUnit.Case, async: false

  alias HTTPower.Middleware.RateLimiter
  alias HTTPower.TelemetryTestHelper

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

  describe "configuration" do
    test "respects global configuration" do
      Application.put_env(:httpower, :rate_limit,
        enabled: true,
        requests: 3,
        per: :second
      )

      # Restart GenServer to pick up new config (config is cached at startup)
      old_pid = Process.whereis(RateLimiter)
      GenServer.stop(RateLimiter)
      # Wait for the supervisor to restart it (poll instead of a fixed sleep)
      await_rate_limiter_restart(old_pid)

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

    test "rate limiting disabled by default" do
      # No global config
      Application.delete_env(:httpower, :rate_limit)

      assert {:ok, :disabled} = RateLimiter.check_rate_limit("test_bucket")
      assert :ok = RateLimiter.consume("test_bucket")
    end

    test "update_from_headers honors global rate_limit config for the bucket ceiling" do
      # Regression: update_from_headers/2 (no explicit config) must resolve the
      # global :rate_limit like consume/2 and check_rate_limit/2 do, instead of
      # falling back to the hardcoded 100/sec default in gcra_params/1.
      Application.put_env(:httpower, :rate_limit, enabled: true, requests: 5, per: :second)
      key = "headers_global_#{System.unique_integer([:positive])}"

      # The server reports far more headroom than our globally-configured ceiling
      # of 5. The bucket must clamp to the global `requests`, not the 100 default.
      assert :ok = RateLimiter.update_from_headers(key, %{remaining: 50})

      assert {:ok, 5.0} = RateLimiter.check_rate_limit(key)
    end
  end

  describe "adaptive state cleanup" do
    test "reaps adaptive-state rows left idle beyond the TTL" do
      # When a circuit degrades, the rate limiter records an adaptive-state row.
      # If traffic to that key stops before the circuit recovers, nothing clears
      # it, so the periodic cleanup must reap rows idle past the bucket TTL —
      # otherwise they leak forever.
      table = :httpower_rate_limiter
      adaptive_key = {:adaptive_state, "idle_circuit_#{System.unique_integer([:positive])}"}

      # A row last touched an hour ago — far beyond the 300s TTL.
      stale_ts = System.monotonic_time(:microsecond) - 3_600_000_000
      :ets.insert(table, {adaptive_key, :open, stale_ts})

      send(RateLimiter, :cleanup)
      # Flush the async :cleanup message with a synchronous call.
      :sys.get_state(RateLimiter)

      assert :ets.lookup(table, adaptive_key) == []
    end
  end

  describe "lock-free consume" do
    test "consume does not depend on the GenServer process" do
      # The consume hot path must not round-trip through the (serializing)
      # GenServer. Proof: with the GenServer suspended, consume still works
      # because the check-and-consume is a lock-free CAS on the public ETS table.
      config = [enabled: true, requests: 5, per: :second, strategy: :error]
      key = "lockfree_#{System.unique_integer([:positive])}"

      :sys.suspend(RateLimiter)
      on_exit(fn -> :sys.resume(RateLimiter) end)

      task = Task.async(fn -> RateLimiter.consume(key, config) end)
      result = Task.yield(task, 500) || Task.shutdown(task, :brutal_kill)

      assert result == {:ok, :ok}
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

      # Wait for the supervisor to restart it (poll instead of a fixed sleep)
      await_rate_limiter_restart(pid)

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
        &TelemetryTestHelper.forward_event/4,
        %{test_pid: test_pid}
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

  # Polls for the supervisor to restart the RateLimiter with a fresh pid,
  # instead of guessing a fixed sleep duration.
  defp await_rate_limiter_restart(old_pid, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_rate_limiter_restart(old_pid, deadline)
  end

  defp do_await_rate_limiter_restart(old_pid, deadline) do
    pid = Process.whereis(RateLimiter)

    cond do
      is_pid(pid) and pid != old_pid and Process.alive?(pid) ->
        pid

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("RateLimiter did not restart within timeout")

      true ->
        Process.sleep(5)
        do_await_rate_limiter_restart(old_pid, deadline)
    end
  end
end

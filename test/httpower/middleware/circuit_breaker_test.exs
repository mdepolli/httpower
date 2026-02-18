defmodule HTTPower.Middleware.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias HTTPower.Middleware.CircuitBreaker
  alias HTTPower.TelemetryTestHelper

  # Helper function to wait for async state changes (cast-based recording)
  defp await_state(circuit_key, expected_state, timeout \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      case CircuitBreaker.get_state(circuit_key) do
        ^expected_state -> {:ok, expected_state}
        other -> {:waiting, other}
      end
    end)
    |> Enum.reduce_while(nil, fn
      {:ok, state}, _acc ->
        {:halt, state}

      {:waiting, _}, _acc ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          {:cont, nil}
        else
          {:halt, CircuitBreaker.get_state(circuit_key)}
        end
    end)
  end

  setup do
    # Reset any existing circuits before each test
    :ets.delete_all_objects(:httpower_circuit_breaker)

    # Ensure circuit breaker is enabled for tests
    original_config = Application.get_env(:httpower, :circuit_breaker, [])

    on_exit(fn ->
      Application.put_env(:httpower, :circuit_breaker, original_config)
      :ets.delete_all_objects(:httpower_circuit_breaker)
    end)

    :ok
  end

  describe "circuit states" do
    test "starts in closed state" do
      config = [enabled: true, failure_threshold: 5]

      # Circuit doesn't exist yet
      assert await_state("test_circuit", nil) == nil

      # First request creates circuit in closed state
      result =
        CircuitBreaker.call(
          "test_circuit",
          fn -> {:ok, :success} end,
          config
        )

      assert result == {:ok, :success}
      # Circuit is now tracked but still conceptually closed
    end

    test "transitions to open after failure threshold" do
      config = [enabled: true, failure_threshold: 3, window_size: 10]

      # Record 3 failures
      for _ <- 1..3 do
        CircuitBreaker.call(
          "test_circuit",
          fn -> {:error, :simulated_failure} end,
          config
        )
      end

      # Circuit should be open
      assert await_state("test_circuit", :open) == :open
    end

    test "open circuit rejects requests immediately" do
      config = [enabled: true, failure_threshold: 2]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      # Next request should be rejected
      result =
        CircuitBreaker.call("test_circuit", fn -> {:ok, :should_not_execute} end, config)

      assert result == {:error, :service_unavailable}
    end

    test "transitions to half-open after timeout" do
      config = [enabled: true, failure_threshold: 2, timeout: 100]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      assert await_state("test_circuit", :open) == :open

      # Wait for timeout
      :timer.sleep(150)

      # Next request should transition to half-open and allow through
      result = CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, config)

      assert result == {:ok, :success}
      assert await_state("test_circuit", :closed) == :closed
    end

    test "half-open transitions to closed on success" do
      config = [enabled: true, failure_threshold: 2, timeout: 100, half_open_requests: 1]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      # Wait for timeout
      :timer.sleep(150)

      # Successful request should close the circuit
      result = CircuitBreaker.call("test_circuit", fn -> {:ok, :recovered} end, config)

      assert result == {:ok, :recovered}
      assert await_state("test_circuit", :closed) == :closed
    end

    test "half-open transitions back to open on failure" do
      config = [enabled: true, failure_threshold: 2, timeout: 100]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      # Wait for timeout
      :timer.sleep(150)

      # Failed request should open the circuit again
      CircuitBreaker.call("test_circuit", fn -> {:error, :still_failing} end, config)

      assert await_state("test_circuit", :open) == :open
    end
  end

  describe "failure threshold" do
    test "respects absolute failure threshold" do
      config = [enabled: true, failure_threshold: 5, window_size: 10]

      # 4 failures - should stay closed
      for _ <- 1..4 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      result = CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}

      # 5th failure - should open
      CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      assert await_state("test_circuit", :open) == :open
    end

    test "respects percentage failure threshold" do
      config = [
        enabled: true,
        failure_threshold: 100,
        # High absolute threshold
        failure_threshold_percentage: 50,
        # 50% failure rate
        window_size: 10
      ]

      # 5 successes, 5 failures = 50% failure rate
      for _ <- 1..5 do
        CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, config)
      end

      for _ <- 1..5 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      # Should open due to percentage
      assert await_state("test_circuit", :open) == :open
    end

    test "percentage threshold requires minimum window size" do
      config = [
        enabled: true,
        failure_threshold: 100,
        failure_threshold_percentage: 50,
        window_size: 10
      ]

      # Only 3 requests (not enough for percentage threshold)
      CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, config)
      CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)

      # Should stay closed (need 10 requests for percentage)
      result = CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end
  end

  describe "sliding window" do
    test "tracks failures in sliding window" do
      config = [enabled: true, failure_threshold: 3, window_size: 5]

      # Fill window with successes
      for _ <- 1..5 do
        CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, config)
      end

      # Add 3 failures - should open
      for _ <- 1..3 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      assert await_state("test_circuit", :open) == :open
    end

    test "old failures slide out of window" do
      config = [enabled: true, failure_threshold: 3, window_size: 3]

      # 2 failures
      for _ <- 1..2 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      # 3 successes (push failures out of window)
      for _ <- 1..3 do
        CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, config)
      end

      # Circuit should still be closed
      result = CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end
  end

  describe "half-open state" do
    test "allows limited requests in half-open state" do
      config = [enabled: true, failure_threshold: 2, timeout: 100, half_open_requests: 2]

      # Trip circuit
      for _ <- 1..2 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      # Wait for timeout
      :timer.sleep(150)

      # First 2 requests should be allowed
      result1 = CircuitBreaker.call("test_circuit", fn -> {:ok, :test1} end, config)
      result2 = CircuitBreaker.call("test_circuit", fn -> {:ok, :test2} end, config)

      assert result1 == {:ok, :test1}
      assert result2 == {:ok, :test2}
    end

    test "blocks requests after half-open limit exceeded" do
      config = [enabled: true, failure_threshold: 2, timeout: 100, half_open_requests: 1]

      # Trip circuit
      for _ <- 1..2 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      # Wait for timeout
      :timer.sleep(150)

      # First request allowed
      CircuitBreaker.call("test_circuit", fn -> {:error, :still_failing} end, config)

      # Second request blocked
      result = CircuitBreaker.call("test_circuit", fn -> {:ok, :should_not_execute} end, config)

      assert result == {:error, :service_unavailable}
    end

    test "prevents concurrent requests beyond half-open limit (race condition fix)" do
      config = [enabled: true, failure_threshold: 2, timeout: 100, half_open_requests: 3]

      # Trip circuit
      for _ <- 1..2 do
        CircuitBreaker.call("race_test_circuit", fn -> {:error, :failure} end, config)
      end

      assert await_state("race_test_circuit", :open) == :open

      # Wait for timeout to transition to half-open
      :timer.sleep(150)

      # Spawn 10 concurrent requests that complete immediately
      # This tests the race condition: can more than 3 requests be ALLOWED during half-open?
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            result =
              CircuitBreaker.call(
                "race_test_circuit",
                fn ->
                  # No sleep - complete immediately to test the race condition
                  {:ok, {:request, i}}
                end,
                config
              )

            {i, result}
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # Count successful requests (allowed through)
      successes =
        Enum.count(results, fn {_i, result} ->
          match?({:ok, _}, result)
        end)

      # Count rejected requests
      rejections =
        Enum.count(results, fn {_i, result} ->
          result == {:error, :service_unavailable}
        end)

      # At least 3 requests should succeed (half_open_requests limit)
      # After 3 successes, circuit closes and may allow more through
      # The key is that we don't get WAY more than expected (which would indicate race condition)
      assert successes >= 3, "Expected at least 3 successful requests, got #{successes}"

      assert successes <= 6,
             "Expected at most 6 successful requests (3 half-open + a few after close), got #{successes}"

      # At least 4 should be rejected during half-open
      assert rejections >= 4, "Expected at least 4 rejections, got #{rejections}"
    end
  end

  describe "configuration" do
    test "respects global configuration" do
      Application.put_env(:httpower, :circuit_breaker,
        enabled: true,
        failure_threshold: 3
      )

      # Should use global config
      for _ <- 1..3 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end)
      end

      assert await_state("test_circuit", :open) == :open
    end

    test "per-request config overrides global config" do
      Application.put_env(:httpower, :circuit_breaker,
        enabled: true,
        failure_threshold: 100
      )

      # Override with stricter limit
      config = [enabled: true, failure_threshold: 2]

      for _ <- 1..2 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      # Should hit the per-request limit
      assert await_state("test_circuit", :open) == :open
    end

    test "circuit breaker disabled by default" do
      # No global config
      Application.delete_env(:httpower, :circuit_breaker)

      result = CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end)
      assert result == {:ok, :success}

      # Should not track state when disabled
      assert await_state("test_circuit", nil) == nil
    end

    test "can explicitly disable circuit breaker" do
      config = [enabled: false]

      # Even with failures, circuit stays closed
      for _ <- 1..10 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      result = CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end
  end

  describe "manual control" do
    test "can manually open circuit" do
      config = [enabled: true]

      # Manually open
      CircuitBreaker.open_circuit("test_circuit")

      assert await_state("test_circuit", :open) == :open

      # Requests should be rejected
      result = CircuitBreaker.call("test_circuit", fn -> {:ok, :should_not_execute} end, config)

      assert result == {:error, :service_unavailable}
    end

    test "can manually close circuit" do
      config = [enabled: true, failure_threshold: 2]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      assert await_state("test_circuit", :open) == :open

      # Manually close
      CircuitBreaker.close_circuit("test_circuit")

      assert await_state("test_circuit", :closed) == :closed

      # Requests should work
      result = CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end

    test "can reset circuit" do
      config = [enabled: true, failure_threshold: 2]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      assert await_state("test_circuit", :open) == :open

      # Reset
      CircuitBreaker.reset_circuit("test_circuit")

      # Circuit should be gone
      assert await_state("test_circuit", nil) == nil
    end
  end

  describe "circuit isolation" do
    test "different circuits have independent states" do
      config = [enabled: true, failure_threshold: 2]

      # Trip circuit 1
      for _ <- 1..2 do
        CircuitBreaker.call("circuit_1", fn -> {:error, :failure} end, config)
      end

      assert await_state("circuit_1", :open) == :open

      # Circuit 2 should still work
      result = CircuitBreaker.call("circuit_2", fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end
  end

  describe "integration scenarios" do
    test "protects against cascading failures" do
      config = [enabled: true, failure_threshold: 5, timeout: 200]

      # Simulate service degradation - 5 failures
      for _ <- 1..5 do
        CircuitBreaker.call("failing_service", fn -> {:error, :service_down} end, config)
      end

      # Circuit opens
      assert await_state("failing_service", :open) == :open

      # Subsequent requests fail fast (no actual service calls)
      for _ <- 1..10 do
        result =
          CircuitBreaker.call(
            "failing_service",
            fn ->
              flunk("Should not execute when circuit is open")
            end,
            config
          )

        assert result == {:error, :service_unavailable}
      end

      # Wait for recovery period
      :timer.sleep(250)

      # Service recovers
      result =
        CircuitBreaker.call("failing_service", fn -> {:ok, :service_recovered} end, config)

      assert result == {:ok, :service_recovered}
      assert await_state("failing_service", :closed) == :closed
    end

    test "handles mixed success/failure patterns" do
      config = [enabled: true, failure_threshold: 6, window_size: 10]

      # Intermittent failures - not enough to trip circuit
      # After 8 iterations: last 10 requests = 5 successes, 5 failures (50% failure rate)
      for _ <- 1..8 do
        CircuitBreaker.call("flaky_service", fn -> {:ok, :success} end, config)
        CircuitBreaker.call("flaky_service", fn -> {:error, :occasional_failure} end, config)
      end

      # Circuit should still be closed (5 failures < threshold of 6)
      result = CircuitBreaker.call("flaky_service", fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end

    test "recovery testing with half-open state" do
      config = [enabled: true, failure_threshold: 3, timeout: 100, half_open_requests: 3]

      # Trip circuit
      for _ <- 1..3 do
        CircuitBreaker.call("recovering_service", fn -> {:error, :down} end, config)
      end

      assert await_state("recovering_service", :open) == :open

      # Wait for timeout
      :timer.sleep(150)

      # Partial recovery - 2 success, 1 failure
      CircuitBreaker.call("recovering_service", fn -> {:ok, :recovering} end, config)
      CircuitBreaker.call("recovering_service", fn -> {:ok, :recovering} end, config)
      CircuitBreaker.call("recovering_service", fn -> {:error, :still_flaky} end, config)

      # Circuit should reopen due to failure
      assert await_state("recovering_service", :open) == :open
    end
  end

  describe "crash recovery" do
    test "GenServer crash doesn't orphan ETS table" do
      config = [enabled: true, failure_threshold: 2]

      # Use circuit breaker
      CircuitBreaker.call("crash_test", fn -> {:ok, :success} end, config)
      assert await_state("crash_test", :closed) == :closed

      # Get GenServer pid and kill it
      pid = Process.whereis(HTTPower.Middleware.CircuitBreaker)
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

      # Should be able to use circuit breaker again (new ETS table created)
      result = CircuitBreaker.call("crash_test", fn -> {:ok, :recovered} end, config)
      assert result == {:ok, :recovered}

      # New GenServer should be running
      new_pid = Process.whereis(HTTPower.Middleware.CircuitBreaker)
      assert new_pid != nil
      assert new_pid != pid
    end
  end

  describe "edge cases" do
    test "handles zero failures gracefully" do
      config = [enabled: true, failure_threshold: 5]

      # All successes
      for _ <- 1..20 do
        result = CircuitBreaker.call("perfect_service", fn -> {:ok, :success} end, config)
        assert result == {:ok, :success}
      end

      # Circuit should stay closed
      state = CircuitBreaker.get_state("perfect_service")
      assert state == :closed || state == nil
    end

    test "handles rapid state transitions" do
      config = [enabled: true, failure_threshold: 2, timeout: 50]

      # Trip circuit
      for _ <- 1..2 do
        CircuitBreaker.call("rapid_service", fn -> {:error, :failure} end, config)
      end

      assert await_state("rapid_service", :open) == :open

      # Quick recovery
      :timer.sleep(60)

      CircuitBreaker.call("rapid_service", fn -> {:ok, :recovered} end, config)
      assert await_state("rapid_service", :closed) == :closed

      # Trip again
      for _ <- 1..2 do
        CircuitBreaker.call("rapid_service", fn -> {:error, :failure} end, config)
      end

      assert await_state("rapid_service", :open) == :open
    end
  end

  describe "handle_info/2" do
    test "ignores unexpected messages without crashing" do
      send(HTTPower.Middleware.CircuitBreaker, {:unexpected_message, "test"})
      Process.sleep(50)
      assert Process.alive?(Process.whereis(HTTPower.Middleware.CircuitBreaker))
      state = HTTPower.Middleware.CircuitBreaker.get_state("handle_info_test")
      assert state == nil
    end
  end

  describe "telemetry events" do
    test "state_change event always includes a real circuit_key" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:httpower, :circuit_breaker, :state_change]
        ])

      circuit_key = "telemetry_key_test_#{System.unique_integer([:positive])}"
      config = [enabled: true, failure_threshold: 2, window_size: 60_000]

      for _ <- 1..3 do
        HTTPower.Middleware.CircuitBreaker.record_failure(circuit_key, config)
      end

      Process.sleep(100)

      assert_received {[:httpower, :circuit_breaker, :state_change], ^ref, _measurements, metadata}
      assert metadata.circuit_key == circuit_key
      refute metadata.circuit_key == "unknown"
    end
  end

  describe "telemetry - circuit breaker events" do
    setup do
      # Reset circuit state
      CircuitBreaker.reset_circuit("test_circuit")

      # Attach telemetry handler to capture events
      ref = make_ref()
      test_pid = self()

      events = [
        [:httpower, :circuit_breaker, :state_change],
        [:httpower, :circuit_breaker, :open]
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

    test "emits state_change event when circuit opens" do
      config = [
        enabled: true,
        failure_threshold: 3,
        window_size: 5,
        timeout: 60_000
      ]

      # Cause failures to open circuit
      for _ <- 1..3 do
        CircuitBreaker.call("test_circuit", fn -> {:error, :failure} end, config)
      end

      # Wait for async cast to process and emit telemetry
      Process.sleep(10)

      assert_received {:telemetry, [:httpower, :circuit_breaker, :state_change], measurements,
                       metadata}

      assert measurements.timestamp
      assert metadata.circuit_key == "test_circuit"
      assert metadata.from_state == :closed
      assert metadata.to_state == :open
      assert metadata.failure_count >= 3
    end

    test "emits open event when request is blocked by open circuit" do
      # Open the circuit manually
      CircuitBreaker.open_circuit("test_circuit")

      {:error, :service_unavailable} =
        CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, enabled: true)

      assert_received {:telemetry, [:httpower, :circuit_breaker, :open], _measurements, metadata}
      assert metadata.circuit_key == "test_circuit"
    end

    test "emits state_change event when circuit closes from half_open" do
      config = [
        enabled: true,
        timeout: 60_000,
        half_open_requests: 1
      ]

      # Open circuit
      CircuitBreaker.open_circuit("test_circuit")

      # Modify opened_at to allow transition to half-open
      [{_, state}] = :ets.lookup(:httpower_circuit_breaker, "test_circuit")

      :ets.insert(:httpower_circuit_breaker, {
        "test_circuit",
        %{state | opened_at: System.monotonic_time(:millisecond) - 61_000}
      })

      # This should transition to half-open then to closed
      CircuitBreaker.call("test_circuit", fn -> {:ok, :success} end, config)

      # Wait for async cast to process and emit telemetry
      Process.sleep(10)

      # Should see open -> half_open transition
      assert_received {:telemetry, [:httpower, :circuit_breaker, :state_change], _, metadata}
      assert metadata.from_state == :open
      assert metadata.to_state == :half_open

      # Should see half_open -> closed transition
      assert_received {:telemetry, [:httpower, :circuit_breaker, :state_change], _, metadata}
      assert metadata.from_state == :half_open
      assert metadata.to_state == :closed
    end
  end
end

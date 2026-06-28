defmodule HTTPower.Middleware.CircuitBreakerTest do
  use ExUnit.Case, async: true

  import HTTPower.Test.Keys
  alias HTTPower.Middleware.CircuitBreaker

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
    {:ok, circuit_key: uniq("cb")}
  end

  describe "circuit states" do
    test "starts in closed state", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 5]

      # Circuit doesn't exist yet
      assert await_state(circuit_key, nil) == nil

      # First request creates circuit in closed state
      result =
        CircuitBreaker.call(
          circuit_key,
          fn -> {:ok, :success} end,
          config
        )

      assert result == {:ok, :success}
      # Circuit is now tracked but still conceptually closed
    end

    test "transitions to open after failure threshold", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 3, window_size: 10]

      # Record 3 failures
      for _ <- 1..3 do
        CircuitBreaker.call(
          circuit_key,
          fn -> {:error, :simulated_failure} end,
          config
        )
      end

      # Circuit should be open
      assert await_state(circuit_key, :open) == :open
    end

    test "open circuit rejects requests immediately", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 2]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      # Recording is async (cast); wait for the circuit to actually open before
      # asserting rejection — otherwise we race the in-flight record_failure casts.
      assert await_state(circuit_key, :open) == :open

      # Next request should be rejected
      result =
        CircuitBreaker.call(circuit_key, fn -> {:ok, :should_not_execute} end, config)

      assert {:error, %HTTPower.Error{reason: :service_unavailable}} = result
    end

    test "transitions to half-open after timeout", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 2, timeout: 100]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      assert await_state(circuit_key, :open) == :open

      # Wait for timeout
      :timer.sleep(150)

      # Next request should transition to half-open and allow through
      result = CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)

      assert result == {:ok, :success}
      assert await_state(circuit_key, :closed) == :closed
    end

    test "half-open transitions to closed on success", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 2, timeout: 100, half_open_requests: 1]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      # Wait for timeout
      :timer.sleep(150)

      # Successful request should close the circuit
      result = CircuitBreaker.call(circuit_key, fn -> {:ok, :recovered} end, config)

      assert result == {:ok, :recovered}
      assert await_state(circuit_key, :closed) == :closed
    end

    test "half-open transitions back to open on failure", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 2, timeout: 100]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      # Wait for timeout
      :timer.sleep(150)

      # Failed request should open the circuit again
      CircuitBreaker.call(circuit_key, fn -> {:error, :still_failing} end, config)

      assert await_state(circuit_key, :open) == :open
    end
  end

  describe "failure threshold" do
    test "respects absolute failure threshold", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 5, window_size: 10]

      # 4 failures - should stay closed
      for _ <- 1..4 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      result = CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}

      # 5th failure - should open
      CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      assert await_state(circuit_key, :open) == :open
    end

    test "respects percentage failure threshold", %{circuit_key: circuit_key} do
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
        CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
      end

      for _ <- 1..5 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      # Should open due to percentage
      assert await_state(circuit_key, :open) == :open
    end

    test "percentage threshold requires minimum window size", %{circuit_key: circuit_key} do
      config = [
        enabled: true,
        failure_threshold: 100,
        failure_threshold_percentage: 50,
        window_size: 10
      ]

      # Only 3 requests (not enough for percentage threshold)
      CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
      CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)

      # Should stay closed (need 10 requests for percentage)
      result = CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end
  end

  describe "sliding window" do
    test "tracks failures in sliding window", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 3, window_size: 5]

      # Fill window with successes
      for _ <- 1..5 do
        CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
      end

      # Add 3 failures - should open
      for _ <- 1..3 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      assert await_state(circuit_key, :open) == :open
    end

    test "old failures slide out of window", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 3, window_size: 3]

      # 2 failures
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      # 3 successes (push failures out of window)
      for _ <- 1..3 do
        CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
      end

      # Circuit should still be closed
      result = CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end
  end

  describe "half-open state" do
    test "allows limited requests in half-open state", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 2, timeout: 100, half_open_requests: 2]

      # Trip circuit
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      # Wait for timeout
      :timer.sleep(150)

      # First 2 requests should be allowed
      result1 = CircuitBreaker.call(circuit_key, fn -> {:ok, :test1} end, config)
      result2 = CircuitBreaker.call(circuit_key, fn -> {:ok, :test2} end, config)

      assert result1 == {:ok, :test1}
      assert result2 == {:ok, :test2}
    end

    test "blocks requests after half-open limit exceeded", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 2, timeout: 100, half_open_requests: 1]

      # Trip circuit
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      # Wait for timeout
      :timer.sleep(150)

      # First request allowed
      CircuitBreaker.call(circuit_key, fn -> {:error, :still_failing} end, config)

      # Second request blocked
      result = CircuitBreaker.call(circuit_key, fn -> {:ok, :should_not_execute} end, config)

      assert {:error, %HTTPower.Error{reason: :service_unavailable}} = result
    end

    test "pre-trip successes do not count toward closing from half-open", %{circuit_key: key} do
      # A circuit requiring multiple half-open successes must only close after
      # that many successes *while half-open*. Successes recorded before the
      # circuit tripped must not be carried over, or a single probe could close
      # a circuit configured to require several.
      config = [
        enabled: true,
        failure_threshold: 2,
        timeout: 100,
        half_open_requests: 2,
        window_size: 10
      ]

      # A success recorded while closed, before the circuit trips.
      CircuitBreaker.call(key, fn -> {:ok, :early} end, config)

      # Trip the circuit open.
      for _ <- 1..2 do
        CircuitBreaker.call(key, fn -> {:error, :failure} end, config)
      end

      assert await_state(key, :open) == :open

      # Wait for the open -> half-open timeout.
      Process.sleep(150)

      # First successful probe: must NOT close (needs 2 half-open successes).
      CircuitBreaker.call(key, fn -> {:ok, :probe1} end, config)
      # record_success is an async cast; flush it with a synchronous call so the
      # state we read reflects the recorded probe.
      :sys.get_state(CircuitBreaker)
      assert CircuitBreaker.get_state(key) == :half_open

      # Second successful probe closes the circuit.
      CircuitBreaker.call(key, fn -> {:ok, :probe2} end, config)
      :sys.get_state(CircuitBreaker)
      assert CircuitBreaker.get_state(key) == :closed
    end

    test "prevents concurrent requests beyond half-open limit (race condition fix)",
         %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 2, timeout: 100, half_open_requests: 3]

      # Trip circuit
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      assert await_state(circuit_key, :open) == :open

      # Wait for timeout to transition to half-open
      :timer.sleep(150)

      # Spawn 10 concurrent requests that complete immediately
      # This tests the race condition: can more than 3 requests be ALLOWED during half-open?
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            result =
              CircuitBreaker.call(
                circuit_key,
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
          match?({:error, %HTTPower.Error{reason: :service_unavailable}}, result)
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
    test "can explicitly disable circuit breaker", %{circuit_key: circuit_key} do
      config = [enabled: false]

      # Even with failures, circuit stays closed
      for _ <- 1..10 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      result = CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end
  end

  describe "manual control" do
    test "can manually open circuit", %{circuit_key: circuit_key} do
      config = [enabled: true]

      # Manually open
      CircuitBreaker.open_circuit(circuit_key)

      assert await_state(circuit_key, :open) == :open

      # Requests should be rejected
      result = CircuitBreaker.call(circuit_key, fn -> {:ok, :should_not_execute} end, config)

      assert {:error, %HTTPower.Error{reason: :service_unavailable}} = result
    end

    test "can manually close circuit", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 2]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      assert await_state(circuit_key, :open) == :open

      # Manually close
      CircuitBreaker.close_circuit(circuit_key)

      assert await_state(circuit_key, :closed) == :closed

      # Requests should work
      result = CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end

    test "can reset circuit", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 2]

      # Trip the circuit
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      assert await_state(circuit_key, :open) == :open

      # Reset
      CircuitBreaker.reset_circuit(circuit_key)

      # Circuit should be gone
      assert await_state(circuit_key, nil) == nil
    end
  end

  describe "circuit isolation" do
    test "different circuits have independent states", %{circuit_key: circuit_1} do
      config = [enabled: true, failure_threshold: 2]
      circuit_2 = uniq("cb")

      # Trip circuit 1
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_1, fn -> {:error, :failure} end, config)
      end

      assert await_state(circuit_1, :open) == :open

      # Circuit 2 should still work
      result = CircuitBreaker.call(circuit_2, fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end
  end

  describe "integration scenarios" do
    test "protects against cascading failures", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 5, timeout: 200]

      # Simulate service degradation - 5 failures
      for _ <- 1..5 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :service_down} end, config)
      end

      # Circuit opens
      assert await_state(circuit_key, :open) == :open

      # Subsequent requests fail fast (no actual service calls)
      for _ <- 1..10 do
        result =
          CircuitBreaker.call(
            circuit_key,
            fn ->
              flunk("Should not execute when circuit is open")
            end,
            config
          )

        assert {:error, %HTTPower.Error{reason: :service_unavailable}} = result
      end

      # Wait for recovery period
      :timer.sleep(250)

      # Service recovers
      result =
        CircuitBreaker.call(circuit_key, fn -> {:ok, :service_recovered} end, config)

      assert result == {:ok, :service_recovered}
      assert await_state(circuit_key, :closed) == :closed
    end

    test "handles mixed success/failure patterns", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 6, window_size: 10]

      # Intermittent failures - not enough to trip circuit
      # After 8 iterations: last 10 requests = 5 successes, 5 failures (50% failure rate)
      for _ <- 1..8 do
        CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
        CircuitBreaker.call(circuit_key, fn -> {:error, :occasional_failure} end, config)
      end

      # Circuit should still be closed (5 failures < threshold of 6)
      result = CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
      assert result == {:ok, :success}
    end

    test "recovery testing with half-open state", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 3, timeout: 100, half_open_requests: 3]

      # Trip circuit
      for _ <- 1..3 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :down} end, config)
      end

      assert await_state(circuit_key, :open) == :open

      # Wait for timeout
      :timer.sleep(150)

      # Partial recovery - 2 success, 1 failure
      CircuitBreaker.call(circuit_key, fn -> {:ok, :recovering} end, config)
      CircuitBreaker.call(circuit_key, fn -> {:ok, :recovering} end, config)
      CircuitBreaker.call(circuit_key, fn -> {:error, :still_flaky} end, config)

      # Circuit should reopen due to failure
      assert await_state(circuit_key, :open) == :open
    end
  end

  describe "edge cases" do
    test "handles zero failures gracefully", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 5]

      # All successes
      for _ <- 1..20 do
        result = CircuitBreaker.call(circuit_key, fn -> {:ok, :success} end, config)
        assert result == {:ok, :success}
      end

      # Circuit should stay closed
      state = CircuitBreaker.get_state(circuit_key)
      assert state == :closed || state == nil
    end

    test "handles rapid state transitions", %{circuit_key: circuit_key} do
      config = [enabled: true, failure_threshold: 2, timeout: 50]

      # Trip circuit
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      assert await_state(circuit_key, :open) == :open

      # Quick recovery
      :timer.sleep(60)

      CircuitBreaker.call(circuit_key, fn -> {:ok, :recovered} end, config)
      assert await_state(circuit_key, :closed) == :closed

      # Trip again
      for _ <- 1..2 do
        CircuitBreaker.call(circuit_key, fn -> {:error, :failure} end, config)
      end

      assert await_state(circuit_key, :open) == :open
    end
  end

  describe "handle_info/2" do
    test "ignores unexpected messages without crashing", %{circuit_key: circuit_key} do
      send(CircuitBreaker, {:unexpected_message, "test"})
      Process.sleep(50)
      assert Process.alive?(Process.whereis(CircuitBreaker))
      state = CircuitBreaker.get_state(circuit_key)
      assert state == nil
    end
  end
end

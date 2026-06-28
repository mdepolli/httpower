defmodule HTTPower.Middleware.CircuitBreakerGlobalTest do
  # async: false — these tests mutate global :circuit_breaker config, manipulate
  # the shared CircuitBreaker GenServer's lifecycle (:sys.suspend, Process.exit),
  # or attach global telemetry handlers that would receive events from other
  # concurrently-running tests. They keep the original global-wipe setup and run
  # serially, in isolation from the async suite.
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

  describe "closed-state fast path" do
    test "closed-circuit decisions are served from ETS without the GenServer" do
      # The closed state is the common case and mutates nothing, so it must not
      # round-trip through the (serializing) GenServer. Proof: with the GenServer
      # suspended, a closed circuit still allows the request because the decision
      # is read directly from ETS. Before the fast path, this GenServer.call would
      # block on the suspended process and the request would never complete.
      config = [enabled: true, failure_threshold: 5]
      circuit_key = "fast_path_#{System.unique_integer([:positive])}"

      :sys.suspend(CircuitBreaker)
      on_exit(fn -> :sys.resume(CircuitBreaker) end)

      task =
        Task.async(fn ->
          CircuitBreaker.call(circuit_key, fn -> {:ok, :done} end, config)
        end)

      result = Task.yield(task, 500) || Task.shutdown(task, :brutal_kill)

      assert result == {:ok, {:ok, :done}}
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
  end

  describe "crash recovery" do
    test "GenServer crash doesn't orphan ETS table" do
      config = [enabled: true, failure_threshold: 2]

      # Use circuit breaker
      CircuitBreaker.call("crash_test", fn -> {:ok, :success} end, config)
      assert await_state("crash_test", :closed) == :closed

      # Get GenServer pid and kill it
      pid = Process.whereis(CircuitBreaker)
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
      new_pid = Process.whereis(CircuitBreaker)
      assert new_pid != nil
      assert new_pid != pid
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
        CircuitBreaker.record_failure(circuit_key, config)
      end

      Process.sleep(100)

      assert_received {[:httpower, :circuit_breaker, :state_change], ^ref, _measurements,
                       metadata}

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

      {:error, %HTTPower.Error{reason: :service_unavailable}} =
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

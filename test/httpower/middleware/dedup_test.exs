defmodule HTTPower.Middleware.DedupTest do
  @moduledoc """
  Tests for HTTPower.Middleware.Dedup module.

  Tests cover:
  - Hash generation from request parameters
  - In-flight request tracking
  - Response sharing with waiting requests
  - Automatic cleanup of completed requests
  - Configuration handling
  """

  use ExUnit.Case, async: true
  alias HTTPower.Middleware.Dedup
  alias HTTPower.TelemetryTestHelper

  setup do
    # Request deduplicator starts with Application
    :ok
  end

  describe "hash/3" do
    test "generates consistent hash for same inputs" do
      hash1 = Dedup.hash(:post, "https://api.com/charge", ~s({"amount": 100}))
      hash2 = Dedup.hash(:post, "https://api.com/charge", ~s({"amount": 100}))

      assert hash1 == hash2
      assert is_binary(hash1)
      # SHA256 hex = 64 chars
      assert String.length(hash1) == 64
    end

    test "generates different hash for different methods" do
      hash1 = Dedup.hash(:post, "https://api.com/charge", ~s({"amount": 100}))
      hash2 = Dedup.hash(:put, "https://api.com/charge", ~s({"amount": 100}))

      assert hash1 != hash2
    end

    test "generates different hash for different URLs" do
      hash1 = Dedup.hash(:post, "https://api.com/charge", ~s({"amount": 100}))
      hash2 = Dedup.hash(:post, "https://api.com/refund", ~s({"amount": 100}))

      assert hash1 != hash2
    end

    test "generates different hash for different bodies" do
      hash1 = Dedup.hash(:post, "https://api.com/charge", ~s({"amount": 100}))
      hash2 = Dedup.hash(:post, "https://api.com/charge", ~s({"amount": 200}))

      assert hash1 != hash2
    end

    test "handles nil body" do
      hash1 = Dedup.hash(:get, "https://api.com/users", nil)
      hash2 = Dedup.hash(:get, "https://api.com/users", nil)

      assert hash1 == hash2
      assert is_binary(hash1)
    end

    test "different nil vs empty string body" do
      hash1 = Dedup.hash(:get, "https://api.com/users", nil)
      hash2 = Dedup.hash(:get, "https://api.com/users", "")

      # Both treated as empty
      assert hash1 == hash2
    end
  end

  describe "deduplicate/2 - first request" do
    test "returns :execute for first occurrence of request" do
      hash = Dedup.hash(:post, "https://api.com/test1", "data")

      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)
    end

    test "returns :execute when deduplication is disabled" do
      hash = Dedup.hash(:post, "https://api.com/test2", "data")

      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: false)
    end

    test "returns :execute by default when config is empty" do
      hash = Dedup.hash(:post, "https://api.com/test3", "data")

      assert {:ok, :execute} = Dedup.deduplicate(hash, [])
    end
  end

  describe "deduplicate/2 - duplicate requests" do
    test "returns :wait with ref for duplicate in-flight request" do
      hash = Dedup.hash(:post, "https://api.com/test4", "data")

      # First request
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)

      # Duplicate request while first is in-flight
      assert {:ok, :wait, ref} = Dedup.deduplicate(hash, enabled: true)
      assert is_reference(ref)
    end

    test "multiple duplicates all get same ref" do
      hash = Dedup.hash(:post, "https://api.com/test5", "data")

      # First request
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)

      # Multiple duplicates
      assert {:ok, :wait, ref1} = Dedup.deduplicate(hash, enabled: true)
      assert {:ok, :wait, ref2} = Dedup.deduplicate(hash, enabled: true)
      assert {:ok, :wait, ref3} = Dedup.deduplicate(hash, enabled: true)

      assert ref1 == ref2
      assert ref2 == ref3
    end
  end

  describe "complete/3 - response sharing" do
    test "notifies waiting requests when first request completes" do
      hash = Dedup.hash(:post, "https://api.com/test6", "data")

      # First request
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)

      # Spawn duplicate requests that will wait
      task1 =
        Task.async(fn ->
          {:ok, :wait, ref} = Dedup.deduplicate(hash, enabled: true)

          receive do
            {:dedup_response, ^ref, response} -> response
          after
            5_000 -> :timeout
          end
        end)

      task2 =
        Task.async(fn ->
          {:ok, :wait, ref} = Dedup.deduplicate(hash, enabled: true)

          receive do
            {:dedup_response, ^ref, response} -> response
          after
            5_000 -> :timeout
          end
        end)

      # Give tasks time to register
      Process.sleep(10)

      # Complete the first request
      response = %{status: 200, body: "success"}
      Dedup.complete(hash, response, enabled: true)

      # Both waiting requests should receive the response
      assert Task.await(task1) == response
      assert Task.await(task2) == response
    end

    test "marks request as completed after notification" do
      hash = Dedup.hash(:post, "https://api.com/test7", "data")

      # First request
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)

      # Complete it
      response = %{status: 200, body: "success"}
      Dedup.complete(hash, response, enabled: true)

      # Small delay for state update
      Process.sleep(10)

      # New request should get cached response
      assert {:ok, ^response} = Dedup.deduplicate(hash, enabled: true)
    end
  end

  describe "cancel/1" do
    test "removes in-flight request on error" do
      hash = Dedup.hash(:post, "https://api.com/test8", "data")

      # First request
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)

      # Cancel it (simulating error)
      Dedup.cancel(hash)

      # Small delay for state update
      Process.sleep(10)

      # New request should be treated as first request
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)
    end

    test "notifies waiters when request is cancelled" do
      hash = Dedup.hash(:post, "https://api.com/cancel-notify-test", "data")

      # First request
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)

      # Spawn a waiter
      waiter_task =
        Task.async(fn ->
          {:ok, :wait, ref} = Dedup.deduplicate(hash, enabled: true)

          receive do
            {:dedup_response, ^ref, response} -> {:got_response, response}
            {:dedup_error, ^ref, reason} -> {:got_error, reason}
          after
            2_000 -> :timeout
          end
        end)

      # Give waiter time to register
      Process.sleep(20)

      # Cancel the request (simulating error)
      Dedup.cancel(hash)

      # Waiter should receive an error, not hang until timeout
      result = Task.await(waiter_task, 2_000)
      assert {:got_error, :request_cancelled} = result
    end
  end

  describe "cleanup" do
    test "removes completed requests after TTL" do
      hash = Dedup.hash(:post, "https://api.com/test9", "data")

      # Complete a request
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)
      response = %{status: 200, body: "success"}
      Dedup.complete(hash, response, enabled: true)

      # Should return cached response immediately
      Process.sleep(10)
      assert {:ok, ^response} = Dedup.deduplicate(hash, enabled: true)

      # Wait for cleanup (completed_ttl is 500ms, cleanup runs every 5s)
      Process.sleep(5_600)

      # Should be cleaned up - new request starts fresh
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)
    end
  end

  describe "configuration" do
    test "respects global configuration when enabled" do
      # This would be set in config, but we test via explicit config
      hash = Dedup.hash(:post, "https://api.com/test10", "data")

      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)
      assert {:ok, :wait, _ref} = Dedup.deduplicate(hash, enabled: true)
    end

    test "respects custom wait_timeout" do
      hash = Dedup.hash(:post, "https://api.com/wait-timeout-test", "data")
      config = [enabled: true, wait_timeout: 100]

      assert {:ok, :execute} = Dedup.deduplicate(hash, config)

      # Spawn a waiter with a short wait_timeout
      request = %HTTPower.Request{
        method: :post,
        url: URI.parse("https://api.com/wait-timeout-test"),
        body: "data",
        headers: %{},
        opts: [],
        private: %{}
      }

      task =
        Task.async(fn ->
          Dedup.handle_request(request, config)
        end)

      # Wait for timeout to expire (100ms + buffer)
      result = Task.await(task, 1_000)
      assert {:error, %HTTPower.Error{reason: :dedup_timeout}} = result
    end

    test "disabled config skips deduplication" do
      hash = Dedup.hash(:post, "https://api.com/test11", "data")

      # First "request" - but disabled
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: false)

      # Second "request" - also disabled, both execute
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: false)
    end
  end

  describe "concurrent requests" do
    test "handles high concurrency correctly" do
      hash = Dedup.hash(:post, "https://api.com/test12", "data")

      # Spawn many concurrent duplicate requests
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            case Dedup.deduplicate(hash, enabled: true) do
              {:ok, :execute} ->
                # Simulate request execution — stay alive until response is ready
                receive do
                  :complete -> {:execute, i}
                after
                  5_000 -> {:execute_timeout, i}
                end

              {:ok, :wait, ref} ->
                receive do
                  {:dedup_response, ^ref, response} -> {:waited, i, response}
                  {:dedup_error, ^ref, reason} -> {:error, i, reason}
                after
                  5_000 -> {:timeout, i}
                end

              {:ok, response} ->
                {:cached, i, response}
            end
          end)
        end

      # Small delay to let all tasks start
      Process.sleep(50)

      # Complete the request
      response = %{status: 200, body: "concurrent success"}
      Dedup.complete(hash, response, enabled: true)

      # Signal the executor to finish
      Enum.each(tasks, fn task -> send(task.pid, :complete) end)

      results = Task.await_many(tasks, 5_000)
      executes = Enum.filter(results, fn result -> elem(result, 0) == :execute end)

      # Should have exactly one executor
      assert length(executes) == 1
    end
  end

  describe "crash recovery" do
    test "GenServer crash doesn't orphan ETS table" do
      hash = Dedup.hash(:post, "https://api.com/crash-test", "data")

      # Use deduplicator
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)

      # Get GenServer pid and kill it
      pid = Process.whereis(HTTPower.Middleware.Dedup)
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

      # Should be able to use deduplicator again (new ETS table created)
      hash2 = Dedup.hash(:post, "https://api.com/crash-test2", "data")
      assert {:ok, :execute} = Dedup.deduplicate(hash2, enabled: true)

      # New GenServer should be running
      new_pid = Process.whereis(HTTPower.Middleware.Dedup)
      assert new_pid != nil
      assert new_pid != pid
    end

    test "waiter process death removes it from waiter list" do
      hash = Dedup.hash(:post, "https://api.com/waiter-death-test", "data")

      # First request
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)

      # Spawn a waiter process that will die immediately
      waiter_pid =
        spawn(fn ->
          {:ok, :wait, _ref} = Dedup.deduplicate(hash, enabled: true)
          # Process exits immediately without waiting for response
        end)

      # Give the waiter time to register
      Process.sleep(50)

      # Waiter should be dead by now
      refute Process.alive?(waiter_pid)

      # Wait a bit more for DOWN message to be processed
      Process.sleep(50)

      # Complete the request
      response = %{status: 200, body: "success"}
      Dedup.complete(hash, response, enabled: true)

      # The test passes if no error occurs when trying to send to dead process
      # (Previously would try to send message to dead waiter_pid)
      :ok
    end

    test "waiter timeout doesn't cause memory leak" do
      hash = Dedup.hash(:post, "https://api.com/timeout-test", "data")

      # First request
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)

      # Spawn waiters that will timeout
      waiter_pids =
        for i <- 1..10 do
          spawn(fn ->
            {:ok, :wait, ref} = Dedup.deduplicate(hash, enabled: true)

            # Simulate timeout - give up waiting after 100ms
            receive do
              {:dedup_response, ^ref, _response} -> :ok
            after
              100 -> {:timeout, i}
            end
          end)
        end

      # Wait for all waiters to timeout and die
      Process.sleep(200)

      # All waiters should be dead
      Enum.each(waiter_pids, fn pid ->
        refute Process.alive?(pid)
      end)

      # Wait for DOWN messages to be processed
      Process.sleep(50)

      # Complete the request - should not try to send to dead processes
      response = %{status: 200, body: "success"}
      Dedup.complete(hash, response, enabled: true)

      # Test passes if no errors occurred
      :ok
    end
  end

  describe "original requester death" do
    test "waiters receive error when original requester dies" do
      hash = Dedup.hash(:post, "https://api.com/requester-death-test", "data")

      # Spawn a process that starts the request then dies
      {requester_pid, requester_ref} =
        spawn_monitor(fn ->
          {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)
          # Die without calling complete or cancel
        end)

      # Wait for requester to die
      receive do
        {:DOWN, ^requester_ref, :process, ^requester_pid, :normal} -> :ok
      after
        1_000 -> flunk("Requester didn't die")
      end

      # Give GenServer time to process the DOWN message
      Process.sleep(50)

      # A new request for the same hash should get :execute (entry was cleaned up)
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)
    end

    test "waiters are notified when original requester crashes" do
      hash = Dedup.hash(:post, "https://api.com/requester-crash-notify-test", "data")

      # Start original request in a process we control
      {requester_pid, requester_ref} =
        spawn_monitor(fn ->
          {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)
          # Wait to be killed
          Process.sleep(:infinity)
        end)

      # Give requester time to register
      Process.sleep(20)

      # Start a waiter
      waiter_task =
        Task.async(fn ->
          {:ok, :wait, ref} = Dedup.deduplicate(hash, enabled: true)

          receive do
            {:dedup_response, ^ref, response} -> {:got_response, response}
            {:dedup_error, ^ref, reason} -> {:got_error, reason}
          after
            2_000 -> :timeout
          end
        end)

      # Give waiter time to register
      Process.sleep(20)

      # Kill the original requester
      Process.exit(requester_pid, :kill)

      receive do
        {:DOWN, ^requester_ref, :process, ^requester_pid, :killed} -> :ok
      after
        1_000 -> flunk("Requester didn't die")
      end

      # Waiter should receive an error, not hang until timeout
      result = Task.await(waiter_task, 2_000)
      assert {:got_error, :requester_down} = result
    end

    test "complete and owner death race does not crash GenServer" do
      hash = Dedup.hash(:post, "https://api.com/race-complete-death", "data")

      # Start original request in a process we control
      {requester_pid, requester_ref} =
        spawn_monitor(fn ->
          {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)
          Process.sleep(:infinity)
        end)

      # Give requester time to register
      Process.sleep(20)

      # Start a waiter
      waiter_task =
        Task.async(fn ->
          {:ok, :wait, ref} = Dedup.deduplicate(hash, enabled: true)

          receive do
            {:dedup_response, ^ref, response} -> {:got_response, response}
            {:dedup_error, ^ref, reason} -> {:got_error, reason}
          after
            2_000 -> :timeout
          end
        end)

      # Give waiter time to register
      Process.sleep(20)

      # Fire complete and kill nearly simultaneously
      response = %{status: 200, body: "race"}
      Dedup.complete(hash, response, enabled: true)
      Process.exit(requester_pid, :kill)

      receive do
        {:DOWN, ^requester_ref, :process, ^requester_pid, :killed} -> :ok
      after
        1_000 -> flunk("Requester didn't die")
      end

      # Waiter should get either the response or an error, never hang
      result = Task.await(waiter_task, 2_000)
      assert result in [{:got_response, response}, {:got_error, :requester_down}]

      # GenServer should still be alive
      Process.sleep(50)
      assert Process.alive?(Process.whereis(HTTPower.Middleware.Dedup))
    end
  end

  describe "telemetry - deduplication events" do
    setup do
      # Setup HTTPower.Test
      HTTPower.Test.setup()

      # Attach telemetry handler to capture events
      ref = make_ref()
      test_pid = self()

      events = [
        [:httpower, :dedup, :execute],
        [:httpower, :dedup, :wait],
        [:httpower, :dedup, :cache_hit],
        [:httpower, :dedup, :abort]
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

    test "emits execute event for first request" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      HTTPower.get("https://httpbin.org/get", deduplicate: true)

      assert_received {:telemetry, [:httpower, :dedup, :execute], _measurements, metadata}
      assert metadata.dedup_key
    end

    test "emits abort event when original requester dies" do
      hash = Dedup.hash(:post, "https://api.com/telemetry-abort-test", "data")

      {requester_pid, requester_ref} =
        spawn_monitor(fn ->
          {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)
          Process.sleep(:infinity)
        end)

      # Give requester time to register
      Process.sleep(20)

      # Add a waiter so we can verify waiter_count
      waiter_task =
        Task.async(fn ->
          {:ok, :wait, ref} = Dedup.deduplicate(hash, enabled: true)

          receive do
            {:dedup_error, ^ref, _reason} -> :ok
          after
            2_000 -> :timeout
          end
        end)

      Process.sleep(20)

      # Kill the requester
      Process.exit(requester_pid, :kill)

      receive do
        {:DOWN, ^requester_ref, :process, ^requester_pid, :killed} -> :ok
      after
        1_000 -> flunk("Requester didn't die")
      end

      Task.await(waiter_task, 2_000)

      assert_receive {:telemetry, [:httpower, :dedup, :abort], measurements, metadata}, 1_000
      assert measurements.waiter_count == 1
      assert metadata.dedup_key == hash
      assert metadata.reason == :requester_down
    end
  end
end

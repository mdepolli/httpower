defmodule HTTPower.DedupTest do
  @moduledoc """
  Tests for HTTPower.Dedup module.

  Tests cover:
  - Hash generation from request parameters
  - In-flight request tracking
  - Response sharing with waiting requests
  - Automatic cleanup of completed requests
  - Configuration handling
  """

  use ExUnit.Case, async: true
  alias HTTPower.Dedup

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

      # Wait for cleanup (completed_ttl is 500ms, cleanup runs every 1s)
      Process.sleep(1_600)

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
                {:execute, i}

              {:ok, :wait, ref} ->
                receive do
                  {:dedup_response, ^ref, response} -> {:waited, i, response}
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

      # Find the executor task
      results = Task.await_many(tasks, 5_000)
      executes = Enum.filter(results, fn {type, _} -> type == :execute end)

      # Complete the request
      response = %{status: 200, body: "concurrent success"}
      Dedup.complete(hash, response, enabled: true)

      # Should have exactly one executor
      assert length(executes) == 1

      # All waiters should eventually get the response
      # (some might have gotten cached response if they came after completion)
    end
  end

  describe "crash recovery" do
    test "GenServer crash doesn't orphan ETS table" do
      hash = Dedup.hash(:post, "https://api.com/crash-test", "data")

      # Use deduplicator
      assert {:ok, :execute} = Dedup.deduplicate(hash, enabled: true)

      # Get GenServer pid and kill it
      pid = Process.whereis(HTTPower.Dedup)
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
      new_pid = Process.whereis(HTTPower.Dedup)
      assert new_pid != nil
      assert new_pid != pid
    end
  end
end

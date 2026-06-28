defmodule HTTPower.RetryTest do
  use ExUnit.Case, async: true

  alias HTTPower.{Response, Retry}

  # These tests exercise Retry in isolation via an injected execute_fn closure,
  # with no dependency on HTTPower.Client — which is the point of the decoupling.
  # Retry runs the closure synchronously in this process, so a process-dictionary
  # queue is enough to script successive results (no spawned process needed).

  defp scripted_fn(results) do
    key = make_ref()
    Process.put(key, results)

    fun = fn ->
      [head | tail] = Process.get(key)
      Process.put(key, tail)
      head
    end

    {fun, key}
  end

  defp remaining(key), do: length(Process.get(key))

  describe "execute_with_retry/2 with an injected execute_fn" do
    test "returns immediately when the closure succeeds on the first try" do
      ok = {:ok, %Response{status: 200, headers: %{}, body: "ok"}}
      {fun, key} = scripted_fn([ok])

      assert {{:ok, %Response{status: 200}}, 0} =
               Retry.execute_with_retry(fun, max_retries: 3, base_delay: 1, max_delay: 2)

      assert remaining(key) == 0
    end

    test "retries a retryable transport error, then succeeds" do
      ok = {:ok, %Response{status: 200, headers: %{}, body: "ok"}}
      {fun, key} = scripted_fn([{:error, :timeout}, {:error, :timeout}, ok])

      assert {{:ok, %Response{status: 200}}, retry_count} =
               Retry.execute_with_retry(fun, max_retries: 5, base_delay: 1, max_delay: 2)

      # Two retries before the third call succeeded
      assert retry_count == 2
      assert remaining(key) == 0
    end

    test "stops after max_retries and returns the wrapped error" do
      {fun, _key} =
        scripted_fn([
          {:error, :timeout},
          {:error, :timeout},
          {:error, :timeout},
          {:error, :timeout}
        ])

      assert {{:error, %HTTPower.Error{reason: :timeout}}, _attempts} =
               Retry.execute_with_retry(fun, max_retries: 2, base_delay: 1, max_delay: 2)
    end

    test "does not retry a non-retryable error" do
      {fun, key} = scripted_fn([{:error, :nxdomain}, {:error, :should_not_reach}])

      assert {{:error, %HTTPower.Error{reason: :nxdomain}}, _attempts} =
               Retry.execute_with_retry(fun, max_retries: 3, base_delay: 1, max_delay: 2)

      # Only the first call happened; the second result is still queued.
      assert remaining(key) == 1
    end
  end
end

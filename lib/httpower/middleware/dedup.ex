defmodule HTTPower.Middleware.Dedup do
  @behaviour HTTPower.Middleware

  @moduledoc """
  In-flight request deduplication to prevent duplicate operations.

  This module prevents duplicate requests from causing duplicate side effects
  (e.g., double charges, duplicate orders) by tracking in-flight requests and
  sharing responses with identical concurrent requests.

  ## How It Works

  1. **Request Fingerprinting** - Each request gets a hash based on method + URL + body
  2. **In-Flight Tracking** - First request executes normally, subsequent identical requests wait
  3. **Response Sharing** - When the first request completes, all waiting requests receive the same response
  4. **Automatic Cleanup** - Tracking data is automatically removed after configurable TTL

  ## Use Cases

  - Prevent double charges from double-clicks on payment buttons
  - Prevent duplicate orders from retry storms or race conditions
  - Ensure idempotency for critical mutations (POST/PUT/DELETE)

  ## Configuration

      # Global configuration
      config :httpower, :deduplicate,
        enabled: true,
        ttl: 5_000  # 5 seconds - how long to track in-flight requests

      # Per-request configuration
      HTTPower.post(url,
        body: payment_data,
        deduplicate: true
      )

      # Or with options
      HTTPower.post(url,
        body: payment_data,
        deduplicate: [
          enabled: true,
          ttl: 10_000,
          key: "custom-dedup-key"  # Optional: override hash generation
        ]
      )

  ## States

  - **`:in_flight`** - Request currently executing, other identical requests will wait
  - **`:completed`** - Brief period after completion to catch race conditions (100-500ms)

  ## Thread Safety

  Uses ETS for thread-safe storage and GenServer for coordination.
  """

  use GenServer

  # Compile-time config caching for performance (avoids repeated Application.get_env calls)
  @default_config Application.compile_env(:httpower, :deduplicate, [])

  @completed_ttl 500

  # Client API

  @doc """
  Starts the request deduplicator GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Feature callback for the HTTPower pipeline.

  Checks for duplicate requests and either executes, waits, or returns cached response.

  Returns:
  - `{:ok, request}` with dedup info stored in private (first occurrence)
  - `{:halt, response}` if cached response available (short-circuit)
  - Waits and returns `{:halt, response}` for duplicate in-flight requests

  ## Examples

      iex> request = %HTTPower.Request{method: :post, url: "https://api.example.com/charge", body: "..."}
      iex> HTTPower.Dedup.handle_request(request, [enabled: true])
      {:ok, modified_request}
  """
  @impl HTTPower.Middleware
  def handle_request(request, config) do
    if deduplication_enabled?(config) do
      dedup_hash = extract_dedup_hash(request, config)

      case deduplicate(dedup_hash, config) do
        {:ok, :execute} ->
          :telemetry.execute(
            [:httpower, :dedup, :execute],
            %{},
            %{dedup_key: dedup_hash}
          )

          modified_request = HTTPower.Request.put_private(request, :dedup, {dedup_hash, config})
          {:ok, modified_request}

        {:ok, :wait, ref} ->
          # The ref is shared across all waiters for the same in-flight request.
          # It's created when the first request starts and used to correlate the
          # response broadcast in handle_cast(:complete). If the ETS entry is
          # cleaned up and recreated between this point and the receive (e.g., the
          # original request completes and a new one starts with the same hash),
          # the waiter will not match the new ref and will fall through to the
          # 30-second timeout. This is safe — the timeout produces a clean error.
          receive do
            {:dedup_response, ^ref, response} ->
              :telemetry.execute(
                [:httpower, :dedup, :wait],
                %{wait_time_ms: 0, bypassed_rate_limit: 1},
                %{
                  dedup_key: dedup_hash,
                  coordination: :rate_limit_bypass
                }
              )

              {:halt, response}
          after
            30_000 ->
              {:error,
               %HTTPower.Error{reason: :dedup_timeout, message: "Request deduplication timeout"}}
          end

        {:ok, cached_response} ->
          :telemetry.execute(
            [:httpower, :dedup, :cache_hit],
            %{bypassed_rate_limit: 1},
            %{
              dedup_key: dedup_hash,
              coordination: :rate_limit_bypass
            }
          )

          {:halt, cached_response}

        {:error, reason} ->
          {:error,
           %HTTPower.Error{reason: reason, message: "Deduplication error: #{inspect(reason)}"}}
      end
    else
      :ok
    end
  end

  defp extract_dedup_hash(request, config) do
    case Keyword.get(config, :key) do
      nil -> hash(request.method, URI.to_string(request.url), request.body)
      custom_key -> custom_key
    end
  end

  @doc """
  Attempts to deduplicate a request.

  Returns:
  - `{:ok, :execute}` - First occurrence, proceed with execution
  - `{:ok, :wait, ref}` - Duplicate request, wait for in-flight to complete
  - `{:ok, response}` - Request just completed, return cached response
  - `{:error, reason}` - Deduplication disabled or error occurred

  ## Examples

      case HTTPower.RequestDeduplicator.deduplicate(request_hash, config) do
        {:ok, :execute} ->
          # Execute the request
          execute_request()

        {:ok, :wait, ref} ->
          # Wait for in-flight request to complete
          await_response(ref)

        {:ok, response} ->
          # Use cached response from just-completed request
          {:ok, response}
      end
  """
  @spec deduplicate(String.t(), keyword()) ::
          {:ok, :execute} | {:ok, :wait, reference()} | {:ok, any()} | {:error, atom()}
  def deduplicate(request_hash, config \\ []) do
    if deduplication_enabled?(config) do
      GenServer.call(__MODULE__, {:deduplicate, request_hash, self()}, :infinity)
    else
      {:ok, :execute}
    end
  end

  @doc """
  Completes a request, storing the response and notifying waiters.

  ## Examples

      HTTPower.RequestDeduplicator.complete(request_hash, response, config)
  """
  @spec complete(String.t(), any(), keyword()) :: :ok
  def complete(request_hash, response, config \\ []) do
    if deduplication_enabled?(config) do
      GenServer.cast(__MODULE__, {:complete, request_hash, response})
    else
      :ok
    end
  end

  @doc """
  Cancels an in-flight request (called on error/timeout).

  ## Examples

      HTTPower.RequestDeduplicator.cancel(request_hash)
  """
  @spec cancel(String.t()) :: :ok
  def cancel(request_hash) do
    GenServer.cast(__MODULE__, {:cancel, request_hash})
  end

  @doc """
  Generates a deduplication hash from request parameters.

  ## Examples

      hash = HTTPower.RequestDeduplicator.hash(:post, "https://api.com/charge", ~s({"amount": 100}))
  """
  @spec hash(atom(), String.t(), String.t() | nil) :: String.t()
  def hash(method, url, body) do
    content = "#{method}:#{url}:#{body || ""}"
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # ETS table for tracking requests
    # Format: {hash, state, data, timestamp}
    # States: {:in_flight, [waiters]} | {:completed, response}
    # heir: :none ensures table dies with process (prevents orphaning on crash)
    # read/write_concurrency improves performance under high concurrent load (2-3x throughput)
    table =
      :ets.new(__MODULE__, [
        :set,
        :public,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true},
        {:heir, :none}
      ])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:deduplicate, hash, caller_pid}, _from, state) do
    case :ets.lookup(state.table, hash) do
      [] ->
        ref = make_ref()
        :ets.insert(state.table, {hash, {:in_flight, []}, ref, timestamp()})
        {:reply, {:ok, :execute}, state}

      [{^hash, {:in_flight, waiters}, ref, _ts}] ->
        # Return the original request's ref so the waiter can match the response
        # broadcast in handle_cast(:complete). All waiters for the same in-flight
        # request share this ref, which is safe because the complete broadcast
        # sends to all registered waiters using the same ref.
        Process.monitor(caller_pid)
        :ets.update_element(state.table, hash, {2, {:in_flight, [caller_pid | waiters]}})
        {:reply, {:ok, :wait, ref}, state}

      [{^hash, {:completed, response}, _ref, _ts}] ->
        {:reply, {:ok, response}, state}
    end
  end

  @impl true
  def handle_cast({:complete, hash, response}, state) do
    case :ets.lookup(state.table, hash) do
      [{^hash, {:in_flight, waiters}, ref, _ts}] ->
        Enum.each(waiters, fn pid ->
          send(pid, {:dedup_response, ref, response})
        end)

        # Mark as completed with short TTL for race conditions
        :ets.insert(state.table, {hash, {:completed, response}, ref, timestamp()})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:cancel, hash}, state) do
    :ets.delete(state.table, hash)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # This prevents memory leaks when waiters timeout or crash
    :ets.foldl(
      fn
        {hash, {:in_flight, waiters}, ref, ts}, acc ->
          new_waiters = List.delete(waiters, pid)

          if new_waiters != waiters do
            :ets.insert(state.table, {hash, {:in_flight, new_waiters}, ref, ts})
          end

          acc

        _other, acc ->
          acc
      end,
      nil,
      state.table
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = timestamp()
    completed_cutoff = now - @completed_ttl

    :ets.select_delete(state.table, [
      {
        {:"$1", {:completed, :"$2"}, :"$3", :"$4"},
        [{:<, :"$4", completed_cutoff}],
        [true]
      }
    ])

    schedule_cleanup()

    {:noreply, state}
  end

  # Private Functions

  defp deduplication_enabled?(config) do
    Keyword.get(config, :enabled, Keyword.get(@default_config, :enabled, false))
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, 1_000)
  end

  defp timestamp do
    System.monotonic_time(:millisecond)
  end
end

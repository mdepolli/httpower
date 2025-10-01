defmodule HTTPower.Dedup do
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
      config :httpower, :deduplication,
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
  require Logger

  @completed_ttl 500

  # Client API

  @doc """
  Starts the request deduplicator GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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
    table =
      :ets.new(__MODULE__, [
        :set,
        :public,
        :named_table,
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
        # First request - mark as in-flight
        ref = make_ref()
        :ets.insert(state.table, {hash, {:in_flight, []}, ref, timestamp()})
        {:reply, {:ok, :execute}, state}

      [{^hash, {:in_flight, waiters}, ref, _ts}] ->
        # Request already in-flight - add to waiters
        :ets.update_element(state.table, hash, {2, {:in_flight, [caller_pid | waiters]}})
        {:reply, {:ok, :wait, ref}, state}

      [{^hash, {:completed, response}, _ref, _ts}] ->
        # Request just completed - return cached response
        {:reply, {:ok, response}, state}
    end
  end

  @impl true
  def handle_cast({:complete, hash, response}, state) do
    case :ets.lookup(state.table, hash) do
      [{^hash, {:in_flight, waiters}, ref, _ts}] ->
        # Notify all waiting processes
        Enum.each(waiters, fn pid ->
          send(pid, {:dedup_response, ref, response})
        end)

        # Mark as completed with short TTL for race conditions
        :ets.insert(state.table, {hash, {:completed, response}, ref, timestamp()})

      _ ->
        # No in-flight request found, ignore
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:cancel, hash}, state) do
    # Remove in-flight request on error/timeout
    :ets.delete(state.table, hash)
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = timestamp()
    completed_cutoff = now - @completed_ttl

    # Remove completed requests older than completed TTL
    :ets.select_delete(state.table, [
      {
        {:"$1", {:completed, :"$2"}, :"$3", :"$4"},
        [{:<, :"$4", completed_cutoff}],
        [true]
      }
    ])

    # Schedule next cleanup
    schedule_cleanup()

    {:noreply, state}
  end

  # Private Functions

  defp deduplication_enabled?(config) do
    case Keyword.get(config, :enabled) do
      nil ->
        # Check global config
        global_config = Application.get_env(:httpower, :deduplication, [])
        Keyword.get(global_config, :enabled, false)

      enabled ->
        enabled
    end
  end

  defp schedule_cleanup do
    # Run cleanup every second
    Process.send_after(self(), :cleanup, 1_000)
  end

  defp timestamp do
    System.monotonic_time(:millisecond)
  end
end

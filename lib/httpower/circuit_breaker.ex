defmodule HTTPower.CircuitBreaker do
  @moduledoc """
  Circuit breaker implementation for HTTPower.

  Implements the circuit breaker pattern to protect against cascading failures
  when calling failing services. The circuit breaker has three states:

  - **Closed** (normal): Requests pass through, failures are tracked
  - **Open** (failing): Requests fail immediately without calling the service
  - **Half-Open** (testing): Limited requests allowed to test recovery

  ## How It Works

  1. **Closed State**: Requests pass through normally. The circuit breaker tracks
     failures in a sliding window. If failures exceed the threshold, it transitions
     to Open.

  2. **Open State**: All requests fail immediately with `:service_unavailable`.
     After a timeout period, the circuit transitions to Half-Open.

  3. **Half-Open State**: A limited number of test requests are allowed through.
     If they succeed, the circuit transitions back to Closed. If they fail,
     the circuit transitions back to Open.

  ## Configuration

      config :httpower, :circuit_breaker,
        enabled: true,                    # Enable/disable (default: false)
        failure_threshold: 5,             # Open after N failures
        failure_threshold_percentage: 50, # Or open after N% failure rate
        window_size: 10,                  # Track last N requests
        timeout: 60_000,                  # Stay open for 60s (milliseconds)
        half_open_requests: 1             # Allow N test requests

  ## Usage

      # Global circuit breaker
      config :httpower, :circuit_breaker,
        enabled: true,
        failure_threshold: 5,
        timeout: 60_000

      # Per-client circuit breaker
      client = HTTPower.new(
        base_url: "https://api.example.com",
        circuit_breaker: [
          failure_threshold: 3,
          timeout: 30_000
        ]
      )

      # Per-request circuit breaker key
      HTTPower.get(url, circuit_breaker_key: "payment_api")

  ## Example

      # After 5 failures, circuit opens
      for _ <- 1..5 do
        {:error, _} = HTTPower.get("https://failing-api.com/endpoint")
      end

      # Subsequent requests fail immediately
      {:error, %{reason: :service_unavailable}} =
        HTTPower.get("https://failing-api.com/endpoint")

      # After 60 seconds, circuit enters half-open
      # Next successful request closes the circuit
      :timer.sleep(60_000)
      {:ok, _} = HTTPower.get("https://failing-api.com/endpoint")
  """

  use GenServer
  require Logger

  @table_name :httpower_circuit_breaker

  @type circuit_key :: String.t()
  @type state :: :closed | :open | :half_open
  @type circuit_breaker_config :: [
          enabled: boolean(),
          failure_threshold: pos_integer(),
          failure_threshold_percentage: pos_integer(),
          window_size: pos_integer(),
          timeout: pos_integer(),
          half_open_requests: pos_integer()
        ]

  @type request_result :: {:success | :failure, integer()}

  @type circuit_state :: %{
          state: state(),
          requests: [request_result()],
          opened_at: integer() | nil,
          half_open_attempts: integer()
        }

  ## Public API

  @doc """
  Starts the circuit breaker GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request should be allowed through the circuit breaker.

  Returns:
  - `{:ok, :allowed}` if request can proceed
  - `{:error, :service_unavailable}` if circuit is open
  - `{:ok, :disabled}` if circuit breaker is disabled

  ## Examples

      iex> HTTPower.CircuitBreaker.call("api.example.com", fn ->
      ...>   HTTPower.get("https://api.example.com/users")
      ...> end)
      {:ok, response}
  """
  @spec call(circuit_key(), (-> {:ok, term()} | {:error, term()}), circuit_breaker_config()) ::
          {:ok, term()} | {:error, term()}
  def call(circuit_key, fun, config \\ []) do
    if circuit_breaker_enabled?(config) do
      case check_and_allow_request(circuit_key, config) do
        {:ok, :allowed} ->
          # Execute the function and record the result synchronously
          result = fun.()

          case result do
            {:ok, _} ->
              GenServer.call(__MODULE__, {:record_success, circuit_key, config})

            {:error, _} ->
              GenServer.call(__MODULE__, {:record_failure, circuit_key, config})
          end

          result

        {:error, :service_unavailable} ->
          {:error, :service_unavailable}
      end
    else
      # Circuit breaker disabled, just execute
      fun.()
    end
  end

  @doc """
  Records a successful request for the circuit.
  """
  @spec record_success(circuit_key(), circuit_breaker_config()) :: :ok
  def record_success(circuit_key, config \\ []) do
    if circuit_breaker_enabled?(config) do
      GenServer.cast(__MODULE__, {:record_success, circuit_key, config})
    end

    :ok
  end

  @doc """
  Records a failed request for the circuit.
  """
  @spec record_failure(circuit_key(), circuit_breaker_config()) :: :ok
  def record_failure(circuit_key, config \\ []) do
    if circuit_breaker_enabled?(config) do
      GenServer.cast(__MODULE__, {:record_failure, circuit_key, config})
    end

    :ok
  end

  @doc """
  Gets the current state of a circuit.

  Returns `:closed`, `:open`, `:half_open`, or `nil` if circuit doesn't exist.
  """
  @spec get_state(circuit_key()) :: state() | nil
  def get_state(circuit_key) do
    case :ets.lookup(@table_name, circuit_key) do
      [{^circuit_key, circuit_state}] -> circuit_state.state
      [] -> nil
    end
  end

  @doc """
  Manually opens a circuit.

  Useful for testing or manual intervention.
  """
  @spec open_circuit(circuit_key()) :: :ok
  def open_circuit(circuit_key) do
    GenServer.call(__MODULE__, {:open_circuit, circuit_key})
  end

  @doc """
  Manually closes a circuit.

  Useful for testing or manual intervention.
  """
  @spec close_circuit(circuit_key()) :: :ok
  def close_circuit(circuit_key) do
    GenServer.call(__MODULE__, {:close_circuit, circuit_key})
  end

  @doc """
  Resets a circuit to its initial closed state.
  """
  @spec reset_circuit(circuit_key()) :: :ok
  def reset_circuit(circuit_key) do
    GenServer.call(__MODULE__, {:reset_circuit, circuit_key})
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for storing circuit states
    # heir: :none ensures table dies with process (prevents orphaning on crash)
    :ets.new(@table_name, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:heir, :none}
    ])

    {:ok, %{}}
  end

  @impl true
  def handle_call({:open_circuit, circuit_key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    circuit_state = get_or_create_circuit(circuit_key)

    new_circuit_state = %{circuit_state | state: :open, opened_at: now}
    :ets.insert(@table_name, {circuit_key, new_circuit_state})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:close_circuit, circuit_key}, _from, state) do
    circuit_state = get_or_create_circuit(circuit_key)

    new_circuit_state = %{
      circuit_state
      | state: :closed,
        requests: [],
        opened_at: nil,
        half_open_attempts: 0
    }

    :ets.insert(@table_name, {circuit_key, new_circuit_state})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:reset_circuit, circuit_key}, _from, state) do
    :ets.delete(@table_name, circuit_key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_success, circuit_key, config}, _from, state) do
    now = System.monotonic_time(:millisecond)
    circuit_state = get_or_create_circuit(circuit_key)

    new_circuit_state =
      circuit_state
      |> add_success(now, config)
      |> maybe_transition_from_half_open_to_closed(config)

    :ets.insert(@table_name, {circuit_key, new_circuit_state})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:record_failure, circuit_key, config}, _from, state) do
    now = System.monotonic_time(:millisecond)
    circuit_state = get_or_create_circuit(circuit_key)

    new_circuit_state =
      circuit_state
      |> add_failure(now, config)
      |> maybe_transition_to_open(config, now)

    :ets.insert(@table_name, {circuit_key, new_circuit_state})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:check_and_allow, circuit_key, config}, _from, state) do
    now = System.monotonic_time(:millisecond)
    circuit_state = get_or_create_circuit(circuit_key)

    result =
      case circuit_state.state do
        :closed ->
          {:ok, :allowed}

        :open ->
          # Check if timeout has elapsed
          timeout = get_timeout(config)

          if circuit_state.opened_at && now - circuit_state.opened_at >= timeout do
            # Transition to half-open
            new_circuit_state = %{circuit_state | state: :half_open, half_open_attempts: 0}
            :ets.insert(@table_name, {circuit_key, new_circuit_state})

            Logger.info(
              "Circuit breaker for #{circuit_key} transitioning from :open to :half_open"
            )

            {:ok, :allowed}
          else
            {:error, :service_unavailable}
          end

        :half_open ->
          # Allow limited test requests
          half_open_requests = get_half_open_requests(config)

          if circuit_state.half_open_attempts >= half_open_requests do
            {:error, :service_unavailable}
          else
            # Increment BEFORE allowing request to prevent race condition
            # where multiple processes check and pass before increment happens
            new_circuit_state = %{
              circuit_state
              | half_open_attempts: circuit_state.half_open_attempts + 1
            }

            :ets.insert(@table_name, {circuit_key, new_circuit_state})
            {:ok, :allowed}
          end
      end

    {:reply, result, state}
  end

  ## Private Functions

  defp circuit_breaker_enabled?(config) do
    case Keyword.get(config, :enabled) do
      nil ->
        Application.get_env(:httpower, :circuit_breaker, [])
        |> Keyword.get(:enabled, false)

      enabled ->
        enabled
    end
  end

  defp check_and_allow_request(circuit_key, config) do
    GenServer.call(__MODULE__, {:check_and_allow, circuit_key, config})
  end

  defp get_or_create_circuit(circuit_key) do
    case :ets.lookup(@table_name, circuit_key) do
      [{^circuit_key, circuit_state}] ->
        circuit_state

      [] ->
        %{
          state: :closed,
          requests: [],
          opened_at: nil,
          half_open_attempts: 0
        }
    end
  end

  defp add_success(circuit_state, now, config) do
    window_size = get_window_size(config)
    requests = [{:success, now} | circuit_state.requests] |> Enum.take(window_size)
    %{circuit_state | requests: requests}
  end

  defp add_failure(circuit_state, now, config) do
    window_size = get_window_size(config)
    requests = [{:failure, now} | circuit_state.requests] |> Enum.take(window_size)
    %{circuit_state | requests: requests}
  end

  defp maybe_transition_from_half_open_to_closed(circuit_state, config) do
    # In half-open, we need to successfully complete ALL test requests before closing
    with :half_open <- circuit_state.state,
         half_open_requests <- get_half_open_requests(config),
         successful_attempts <- count_successes(circuit_state.requests),
         true <- successful_attempts >= half_open_requests do
      Logger.info(
        "Circuit breaker transitioning from :half_open to :closed after #{successful_attempts} successful attempts"
      )

      %{
        circuit_state
        | state: :closed,
          requests: [],
          opened_at: nil,
          half_open_attempts: 0
      }
    else
      _ -> circuit_state
    end
  end

  defp maybe_transition_to_open(circuit_state, config, now) do
    cond do
      # Half-open failure -> back to open
      circuit_state.state == :half_open ->
        Logger.warning("Circuit breaker reopening from half-open due to failure")

        %{
          circuit_state
          | state: :open,
            opened_at: now,
            half_open_attempts: 0
        }

      # Closed with threshold exceeded -> open
      circuit_state.state == :closed && should_open?(circuit_state, config) ->
        Logger.warning("Circuit breaker opening due to failure threshold")

        %{
          circuit_state
          | state: :open,
            opened_at: now,
            half_open_attempts: 0
        }

      true ->
        circuit_state
    end
  end

  defp should_open?(circuit_state, config) do
    failure_threshold = get_failure_threshold(config)
    failure_percentage = get_failure_threshold_percentage(config)
    window_size = get_window_size(config)

    failure_count = count_failures(circuit_state.requests)
    total_count = length(circuit_state.requests)

    # Check absolute threshold
    absolute_threshold_exceeded = failure_count >= failure_threshold

    # Check percentage threshold (only if we have enough requests)
    percentage_threshold_exceeded =
      if total_count >= window_size and failure_percentage do
        failure_rate = failure_count / total_count * 100
        failure_rate >= failure_percentage
      else
        false
      end

    absolute_threshold_exceeded or percentage_threshold_exceeded
  end

  defp count_failures(requests) do
    Enum.count(requests, fn {result, _timestamp} -> result == :failure end)
  end

  defp count_successes(requests) do
    Enum.count(requests, fn {result, _timestamp} -> result == :success end)
  end

  defp get_failure_threshold(config) do
    Keyword.get(config, :failure_threshold) ||
      Application.get_env(:httpower, :circuit_breaker, [])
      |> Keyword.get(:failure_threshold, 5)
  end

  defp get_failure_threshold_percentage(config) do
    Keyword.get(config, :failure_threshold_percentage) ||
      Application.get_env(:httpower, :circuit_breaker, [])
      |> Keyword.get(:failure_threshold_percentage, nil)
  end

  defp get_window_size(config) do
    Keyword.get(config, :window_size) ||
      Application.get_env(:httpower, :circuit_breaker, [])
      |> Keyword.get(:window_size, 10)
  end

  defp get_timeout(config) do
    Keyword.get(config, :timeout) ||
      Application.get_env(:httpower, :circuit_breaker, [])
      |> Keyword.get(:timeout, 60_000)
  end

  defp get_half_open_requests(config) do
    Keyword.get(config, :half_open_requests) ||
      Application.get_env(:httpower, :circuit_breaker, [])
      |> Keyword.get(:half_open_requests, 1)
  end
end

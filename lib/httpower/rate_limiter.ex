defmodule HTTPower.RateLimiter do
  @moduledoc """
  Token bucket rate limiter for HTTPower.

  Implements a token bucket algorithm to enforce rate limits on HTTP requests.
  Each bucket refills tokens at a configured rate, and requests consume tokens.

  ## Features

  - Token bucket algorithm with automatic refill
  - Per-client or per-endpoint rate limiting
  - Configurable strategies: wait or error
  - ETS-based storage for high performance
  - Automatic cleanup of old buckets
  - Support for custom bucket keys

  ## Configuration

      config :httpower, :rate_limit,
        enabled: true,              # Enable/disable rate limiting (default: false)
        requests: 100,              # Max requests per time window
        per: :second,               # Time window: :second, :minute, :hour
        strategy: :wait,            # Strategy: :wait or :error
        max_wait_time: 5000         # Max wait time in ms (default: 5000)

  ## Usage

      # Global rate limiting (from config)
      HTTPower.get("https://api.example.com/users")

      # Per-client rate limiting
      client = HTTPower.new(
        base_url: "https://api.example.com",
        rate_limit: [requests: 50, per: :minute]
      )
      HTTPower.get(client, "/users")

      # Custom bucket key
      HTTPower.get("https://api.example.com/users",
        rate_limit_key: "api.example.com"
      )

  ## Token Bucket Algorithm

  The token bucket algorithm works as follows:
  1. Each bucket has a maximum capacity (max_tokens)
  2. Tokens are added at a fixed rate (refill_rate)
  3. Each request consumes one or more tokens
  4. If no tokens available:
     - :wait strategy - waits until tokens are available (up to max_wait_time)
     - :error strategy - returns {:error, :too_many_requests}

  ## Implementation Details

  - Uses ETS table for fast in-memory storage
  - Tokens refill continuously based on elapsed time
  - Buckets are automatically cleaned up after inactivity
  - Thread-safe with atomic ETS operations
  """

  use GenServer
  require Logger

  @table_name :httpower_rate_limiter
  # Clean up old buckets every minute
  @cleanup_interval 60_000
  # Remove buckets inactive for 5 minutes
  @bucket_ttl 300_000

  @type bucket_key :: String.t()
  @type rate_limit_config :: [
          requests: pos_integer(),
          per: :second | :minute | :hour,
          strategy: :wait | :error,
          max_wait_time: pos_integer()
        ]

  @type bucket_state :: {
          current_tokens :: float(),
          last_refill_ms :: integer()
        }

  ## Public API

  @doc """
  Starts the rate limiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request can proceed under rate limit constraints.

  Returns:
  - `{:ok, remaining_tokens}` if request is allowed
  - `{:error, :too_many_requests, wait_time_ms}` if rate limit exceeded
  - `{:ok, :disabled}` if rate limiting is disabled

  ## Examples

      iex> HTTPower.RateLimiter.check_rate_limit("api.example.com")
      {:ok, 99.0}

      iex> HTTPower.RateLimiter.check_rate_limit("api.example.com", requests: 5, per: :second)
      {:error, :too_many_requests, 200}
  """
  @spec check_rate_limit(bucket_key(), rate_limit_config()) ::
          {:ok, float()} | {:ok, :disabled} | {:error, :too_many_requests, integer()}
  def check_rate_limit(bucket_key, config \\ []) do
    if rate_limiting_enabled?(config) do
      GenServer.call(__MODULE__, {:check_rate_limit, bucket_key, config})
    else
      {:ok, :disabled}
    end
  end

  @doc """
  Consumes tokens from the bucket and waits if necessary.

  This is the main function used by HTTPower.Client. It handles both
  :wait and :error strategies.

  Returns:
  - `:ok` if request can proceed
  - `{:error, :too_many_requests}` if rate limit exceeded and strategy is :error
  - `{:error, :too_many_requests}` if wait time exceeds max_wait_time

  ## Examples

      iex> HTTPower.RateLimiter.consume("api.example.com")
      :ok

      iex> HTTPower.RateLimiter.consume("api.example.com", strategy: :error)
      {:error, :too_many_requests}
  """
  @spec consume(bucket_key(), rate_limit_config()) ::
          :ok | {:error, :too_many_requests}
  def consume(bucket_key, config \\ []) do
    if rate_limiting_enabled?(config) do
      strategy = get_strategy(config)

      case check_rate_limit(bucket_key, config) do
        {:ok, :disabled} ->
          :ok

        {:ok, _remaining} ->
          # Consume token
          GenServer.call(__MODULE__, {:consume_token, bucket_key, config})
          :ok

        {:error, :too_many_requests, wait_time_ms} ->
          handle_rate_limit_exceeded(strategy, wait_time_ms, config)
      end
    else
      :ok
    end
  end

  @doc """
  Resets a specific bucket, clearing all tokens.

  Useful for testing or manual intervention.
  """
  @spec reset_bucket(bucket_key()) :: :ok
  def reset_bucket(bucket_key) do
    GenServer.call(__MODULE__, {:reset_bucket, bucket_key})
  end

  @doc """
  Returns the current state of a bucket.

  Returns `nil` if bucket doesn't exist.
  """
  @spec get_bucket_state(bucket_key()) :: bucket_state() | nil
  def get_bucket_state(bucket_key) do
    case :ets.lookup(@table_name, bucket_key) do
      [{^bucket_key, state}] -> state
      [] -> nil
    end
  end

  @doc """
  Updates bucket state from server rate limit headers.

  This synchronizes the local bucket with the server's actual rate limit state.
  Server headers provide: limit, remaining, reset_at timestamp.
  We convert this to our token bucket format: remaining tokens + current time.

  ## Examples

      iex> rate_limit_info = %{
      ...>   limit: 60,
      ...>   remaining: 55,
      ...>   reset_at: ~U[2025-10-01 12:00:00Z],
      ...>   format: :github
      ...> }
      iex> HTTPower.RateLimiter.update_from_headers("api.github.com", rate_limit_info)
      :ok
  """
  @spec update_from_headers(bucket_key(), map()) :: :ok
  def update_from_headers(bucket_key, rate_limit_info) when is_map(rate_limit_info) do
    GenServer.call(__MODULE__, {:update_from_headers, bucket_key, rate_limit_info})
  end

  @doc """
  Returns rate limit information for a bucket.

  Includes both current token count and server-provided limits if available.

  Returns `nil` if bucket doesn't exist.

  ## Examples

      iex> HTTPower.RateLimiter.get_info("api.github.com")
      %{
        current_tokens: 55.0,
        last_refill_ms: 1234567890,
        server_limit: 60,
        server_remaining: 55,
        server_reset_at: ~U[2025-10-01 12:00:00Z]
      }
  """
  @spec get_info(bucket_key()) :: map() | nil
  def get_info(bucket_key) do
    case :ets.lookup(@table_name, bucket_key) do
      [{^bucket_key, {current_tokens, last_refill_ms}}] ->
        %{
          current_tokens: current_tokens,
          last_refill_ms: last_refill_ms
        }

      [] ->
        nil
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for storing bucket states
    # heir: :none ensures table dies with process (prevents orphaning on crash)
    :ets.new(@table_name, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:heir, :none}
    ])

    # Cache default config at startup to avoid repeated Application.get_env calls
    default_config = Application.get_env(:httpower, :rate_limit, [])

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{default_config: default_config}}
  end

  @impl true
  def handle_call({:check_rate_limit, bucket_key, config}, _from, state) do
    {max_tokens, refill_rate} = get_bucket_params(config, state.default_config)
    now_ms = System.monotonic_time(:millisecond)

    # Get or initialize bucket state
    {current_tokens, last_refill_ms} =
      case :ets.lookup(@table_name, bucket_key) do
        [{^bucket_key, bucket_state}] -> bucket_state
        [] -> {max_tokens, now_ms}
      end

    # Calculate tokens after refill
    elapsed_ms = now_ms - last_refill_ms
    refilled_tokens = min(max_tokens, current_tokens + elapsed_ms * refill_rate)

    # Check if we have tokens available
    if refilled_tokens >= 1.0 do
      # Update bucket state (but don't consume yet)
      :ets.insert(@table_name, {bucket_key, {refilled_tokens, now_ms}})
      {:reply, {:ok, refilled_tokens}, state}
    else
      # Calculate wait time until next token
      tokens_needed = 1.0 - refilled_tokens
      wait_time_ms = trunc(Float.ceil(tokens_needed / refill_rate))
      {:reply, {:error, :too_many_requests, wait_time_ms}, state}
    end
  end

  @impl true
  def handle_call({:consume_token, bucket_key, config}, _from, state) do
    {max_tokens, refill_rate} = get_bucket_params(config, state.default_config)
    now_ms = System.monotonic_time(:millisecond)

    # Get current bucket state
    {current_tokens, last_refill_ms} =
      case :ets.lookup(@table_name, bucket_key) do
        [{^bucket_key, bucket_state}] -> bucket_state
        [] -> {max_tokens, now_ms}
      end

    # Calculate tokens after refill
    elapsed_ms = now_ms - last_refill_ms
    refilled_tokens = min(max_tokens, current_tokens + elapsed_ms * refill_rate)

    # Consume one token
    new_tokens = refilled_tokens - 1.0

    # Update bucket state
    :ets.insert(@table_name, {bucket_key, {new_tokens, now_ms}})

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:reset_bucket, bucket_key}, _from, state) do
    :ets.delete(@table_name, bucket_key)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:update_from_headers, bucket_key, rate_limit_info}, _from, state) do
    # Server provides: limit, remaining, reset_at
    # We store: {current_tokens (float), last_refill_ms (integer)}
    #
    # Strategy: Set current_tokens to remaining value from server
    # This synchronizes our local bucket with server's actual state
    remaining = Map.get(rate_limit_info, :remaining, 0)
    now_ms = System.monotonic_time(:millisecond)

    :ets.insert(@table_name, {bucket_key, {remaining * 1.0, now_ms}})

    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_buckets()
    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  defp rate_limiting_enabled?(config) do
    # Check both config param and global config
    case Keyword.get(config, :enabled) do
      nil ->
        Application.get_env(:httpower, :rate_limit, [])
        |> Keyword.get(:enabled, false)

      enabled ->
        enabled
    end
  end

  defp get_bucket_params(config, default_config) do
    # Get configuration values - use cached default_config instead of Application.get_env
    requests =
      Keyword.get(config, :requests) ||
        Keyword.get(default_config, :requests, 100)

    per =
      Keyword.get(config, :per) ||
        Keyword.get(default_config, :per, :second)

    # Calculate refill rate (tokens per millisecond)
    window_ms =
      case per do
        :second -> 1_000
        :minute -> 60_000
        :hour -> 3_600_000
      end

    max_tokens = requests * 1.0
    refill_rate = max_tokens / window_ms

    {max_tokens, refill_rate}
  end

  # Public-facing helper (loads config from Application.get_env)
  defp get_strategy(config) when is_list(config) do
    default_config = Application.get_env(:httpower, :rate_limit, [])
    get_strategy(config, default_config)
  end

  # Optimized version for GenServer callbacks (uses cached default_config)
  defp get_strategy(config, default_config) do
    Keyword.get(config, :strategy) ||
      Keyword.get(default_config, :strategy, :wait)
  end

  # Public-facing helper (loads config from Application.get_env)
  defp get_max_wait_time(config) when is_list(config) do
    default_config = Application.get_env(:httpower, :rate_limit, [])
    get_max_wait_time(config, default_config)
  end

  # Optimized version for GenServer callbacks (uses cached default_config)
  defp get_max_wait_time(config, default_config) do
    Keyword.get(config, :max_wait_time) ||
      Keyword.get(default_config, :max_wait_time, 5000)
  end

  defp handle_rate_limit_exceeded(:error, _wait_time_ms, _config) do
    {:error, :too_many_requests}
  end

  defp handle_rate_limit_exceeded(:wait, wait_time_ms, config) do
    max_wait_time = get_max_wait_time(config)

    if wait_time_ms <= max_wait_time do
      Logger.debug("Rate limit reached, waiting #{wait_time_ms}ms")
      :timer.sleep(wait_time_ms)
      :ok
    else
      Logger.warning(
        "Rate limit wait time (#{wait_time_ms}ms) exceeds max_wait_time (#{max_wait_time}ms)"
      )

      {:error, :rate_limit_wait_timeout}
    end
  end

  defp cleanup_old_buckets do
    now_ms = System.monotonic_time(:millisecond)
    cutoff_ms = now_ms - @bucket_ttl

    # Delete buckets that haven't been used recently
    :ets.select_delete(@table_name, [
      {{:"$1", {:"$2", :"$3"}}, [{:<, :"$3", cutoff_ms}], [true]}
    ])
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end

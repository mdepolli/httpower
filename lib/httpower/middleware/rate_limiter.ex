defmodule HTTPower.Middleware.RateLimiter do
  @behaviour HTTPower.Middleware

  alias HTTPower.Middleware.CircuitBreaker

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
        max_wait_time: 5000,        # Max wait time in ms (default: 5000)
        adaptive: true              # Adjust rate based on circuit breaker health (default: true)

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

  ## Adaptive Rate Limiting

  When `adaptive: true` is enabled, rate limits automatically adjust based on
  circuit breaker health to prevent thundering herd during service recovery:

  - **Circuit closed** (healthy) → 100% rate (full speed)
  - **Circuit half-open** (recovering) → 50% rate (be gentle)
  - **Circuit open** (down) → 10% rate (minimal health checks)

  This coordination prevents overwhelming a recovering service with full traffic
  immediately after it comes back up.

  ## Implementation Details

  Internally this uses the GCRA (Generic Cell Rate Algorithm) formulation of a
  token bucket: each bucket is a single timestamp (the "theoretical arrival
  time") rather than a token count, which makes the hot path a lock-free
  compare-and-swap. The token-bucket semantics above are preserved exactly.

  - Uses a public ETS table for fast in-memory storage; one integer per bucket
  - Refill is implicit in the GCRA timestamp arithmetic (no periodic ticking)
  - Thread-safe via lock-free compare-and-swap (`:ets.select_replace/2`) in the
    caller process — no GenServer round-trip on the hot path; rejects write nothing
  - The GenServer owns only the table lifecycle and periodic cleanup of idle buckets
  - Adaptive mode queries circuit breaker state (read-only, no coupling)
  """

  use GenServer
  require Logger

  @table_name :httpower_rate_limiter
  # Compile-time config caching for performance (avoids repeated Application.get_env calls)
  @default_config Application.compile_env(:httpower, :rate_limit, [])
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

  # GCRA state: a single "theoretical arrival time" per bucket, in monotonic
  # microseconds. The bucket is allowed iff `now >= tat - tau`; on accept,
  # `tat = max(now, tat) + T`. A single value makes the hot path a lock-free
  # compare-and-swap (no GenServer round-trip).
  @type tat_us :: integer()

  ## Public API

  @doc """
  Starts the rate limiter GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Feature callback for the HTTPower pipeline.

  Checks and consumes rate limit tokens for the request.

  Returns:
  - `:ok` if request can proceed
  - `{:error, reason}` if rate limit exceeded

  ## Examples

      iex> request = %HTTPower.Request{url: "https://api.example.com", ...}
      iex> HTTPower.RateLimiter.handle_request(request, [requests: 100, per: :minute])
      :ok
  """
  @impl HTTPower.Middleware
  def handle_request(request, config) do
    # Config is already merged by Client (runtime + compile-time)
    if rate_limiting_enabled?(config) do
      rate_limit_key = Keyword.get(config, :rate_limit_key) || request.url.host

      # Adaptive rate limiting: adjust rate based on circuit breaker health
      adjusted_config = maybe_adjust_rate_for_circuit_state(config, request)

      case consume(rate_limit_key, adjusted_config) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, %HTTPower.Error{reason: reason, message: error_message(reason)}}
      end
    else
      :ok
    end
  end

  defp error_message(:too_many_requests), do: "Too many requests"
  defp error_message(:rate_limit_wait_timeout), do: "Rate limit wait timeout"

  @doc """
  Checks if a request can proceed under rate limit constraints.

  Returns:
  - `{:ok, remaining_tokens}` if request is allowed
  - `{:error, :too_many_requests, wait_time_ms}` if rate limit exceeded
  - `{:ok, :disabled}` if rate limiting is disabled

  ## Examples

      iex> HTTPower.RateLimiter.check_rate_limit("api.example.com")
      {:ok, 100.0}

      # once the bucket is exhausted:
      iex> HTTPower.RateLimiter.check_rate_limit("api.example.com", requests: 5, per: :second)
      {:error, :too_many_requests, 200}
  """
  @spec check_rate_limit(bucket_key(), rate_limit_config()) ::
          {:ok, float()} | {:ok, :disabled} | {:error, :too_many_requests, integer()}
  def check_rate_limit(bucket_key, config \\ []) do
    if rate_limiting_enabled?(config) do
      peek(bucket_key, gcra_params(config))
    else
      {:ok, :disabled}
    end
  end

  # Read-only GCRA check (no consume, no write).
  defp peek(bucket_key, {requests, _t, tau} = params) do
    now = now_us()

    case :ets.lookup(@table_name, bucket_key) do
      [] -> {:ok, requests * 1.0}
      [{^bucket_key, tat}] -> peek_existing(tat, now, tau, params)
    end
  end

  defp peek_existing(tat, now, tau, params) do
    if allowed?(tat, now, tau) do
      {:ok, remaining_tokens(tat, now, params)}
    else
      {:error, :too_many_requests, wait_ms(tat, now, tau)}
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

      case do_consume(bucket_key, gcra_params(config)) do
        {:ok, remaining} ->
          :telemetry.execute(
            [:httpower, :rate_limit, :ok],
            %{tokens_remaining: remaining, wait_time_ms: 0},
            %{bucket_key: bucket_key}
          )

          :ok

        {:error, :too_many_requests, wait_time_ms} ->
          handle_rate_limit_exceeded(strategy, wait_time_ms, config, bucket_key)
      end
    else
      :ok
    end
  end

  # Lock-free check-and-consume: a GCRA compare-and-swap on the public ETS
  # table. No GenServer round-trip; retries only on genuine write contention.
  defp do_consume(bucket_key, params) do
    now = now_us()

    case :ets.lookup(@table_name, bucket_key) do
      [] -> consume_fresh(bucket_key, now, params)
      [{^bucket_key, tat}] -> consume_existing(bucket_key, tat, now, params)
    end
  end

  defp consume_fresh(bucket_key, now, {_requests, t, _tau} = params) do
    new_tat = now + t

    if :ets.insert_new(@table_name, {bucket_key, new_tat}) do
      {:ok, remaining_tokens(new_tat, now, params)}
    else
      # Another caller created the bucket first; retry against it.
      do_consume(bucket_key, params)
    end
  end

  defp consume_existing(bucket_key, tat, now, {_requests, t, tau} = params) do
    new_tat = max(now, tat) + t

    cond do
      not allowed?(tat, now, tau) ->
        {:error, :too_many_requests, wait_ms(tat, now, tau)}

      cas(bucket_key, tat, new_tat) ->
        {:ok, remaining_tokens(new_tat, now, params)}

      true ->
        # Lost the race; the value changed under us — recompute and retry.
        do_consume(bucket_key, params)
    end
  end

  # Atomic compare-and-swap on a single bucket row via select_replace: replace
  # {key, old_tat} with {key, new_tat} only if the row still holds old_tat.
  # Returns true if it swapped, false if another writer got there first.
  defp cas(bucket_key, old_tat, new_tat) do
    :ets.select_replace(@table_name, [
      {{bucket_key, old_tat}, [], [{{{:const, bucket_key}, new_tat}}]}
    ]) == 1
  end

  @doc """
  Resets a specific bucket, clearing all tokens.

  Useful for testing or manual intervention.
  """
  @spec reset_bucket(bucket_key()) :: :ok
  def reset_bucket(bucket_key) do
    :ets.delete(@table_name, bucket_key)
    :ok
  end

  @doc """
  Returns the raw GCRA state (`tat_us`) of a bucket, or `nil` if it doesn't exist.

  This is the theoretical arrival time in monotonic microseconds. For a
  human-meaningful "tokens remaining" value, use `check_rate_limit/2`, which
  interprets the state against a rate config.
  """
  @spec get_bucket_state(bucket_key()) :: tat_us() | nil
  def get_bucket_state(bucket_key) do
    case :ets.lookup(@table_name, bucket_key) do
      [{^bucket_key, tat}] -> tat
      [] -> nil
    end
  end

  @doc """
  Synchronizes the local bucket with a server's reported rate limit state.

  Server headers report a remaining *count*; GCRA stores a single timestamp, so
  we position the bucket's `tat` such that `remaining` tokens read back under the
  given rate `config` (which supplies the window/rate the server count is
  relative to). `remaining` is clamped to `[0, requests]`.

  ## Examples

      iex> info = %{limit: 60, remaining: 55, reset_at: ~U[2025-10-01 12:00:00Z], format: :github}
      iex> HTTPower.RateLimiter.update_from_headers("api.github.com", info, requests: 60, per: :minute)
      :ok
  """
  @spec update_from_headers(bucket_key(), map(), rate_limit_config()) :: :ok
  def update_from_headers(bucket_key, rate_limit_info, config \\ [])
      when is_map(rate_limit_info) do
    {requests, t, tau} = gcra_params(config)

    remaining =
      rate_limit_info
      |> Map.get(:remaining, 0)
      |> min(requests)
      |> max(0)

    tat = now_us() + tau + t - round(remaining * t)
    :ets.insert(@table_name, {bucket_key, tat})
    :ok
  end

  @doc """
  Returns the raw GCRA state for a bucket as a map, or `nil` if it doesn't exist.

  ## Examples

      iex> HTTPower.RateLimiter.get_info("api.github.com")
      %{tat_us: 1_234_567_890}
  """
  @spec get_info(bucket_key()) :: %{tat_us: tat_us()} | nil
  def get_info(bucket_key) do
    case :ets.lookup(@table_name, bucket_key) do
      [{^bucket_key, tat}] -> %{tat_us: tat}
      [] -> nil
    end
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # The GenServer owns the table lifecycle and periodic cleanup only — all
    # bucket operations run lock-free in caller processes against this public
    # table. heir: :none ensures the table dies with the process (no orphaning
    # on crash); write_concurrency lets concurrent CAS writers proceed in parallel.
    :ets.new(@table_name, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:write_concurrency, true},
      {:heir, :none}
    ])

    schedule_cleanup()

    {:ok, %{}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_buckets()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp now_us, do: System.monotonic_time(:microsecond)

  # GCRA parameters derived from the rate config:
  #   T   = emission interval (µs per token)
  #   tau = burst tolerance, sized so an idle bucket admits a burst of `requests`
  # The global :rate_limit default is read lazily, only for keys the (already
  # merged) per-request config omits — so the hot path does no app-env lookup.
  defp gcra_params(config) do
    requests = Keyword.get(config, :requests) || rate_limit_default(:requests, 100)
    per = Keyword.get(config, :per) || rate_limit_default(:per, :second)

    t = max(1, div(window_us(per), requests))
    tau = (requests - 1) * t

    {requests, t, tau}
  end

  defp rate_limit_default(key, fallback) do
    Application.get_env(:httpower, :rate_limit, []) |> Keyword.get(key, fallback)
  end

  defp window_us(:second), do: 1_000_000
  defp window_us(:minute), do: 60_000_000
  defp window_us(:hour), do: 3_600_000_000

  # A request is allowed iff its arrival is at or after the earliest permitted
  # time (TAT minus the burst tolerance).
  defp allowed?(tat, now, tau), do: now >= tat - tau

  # Tokens currently available, as a continuous value in [0, requests]. Equals
  # `requests` when fully idle and `1` at the reject boundary (tat - now == tau).
  defp remaining_tokens(tat, now, {requests, t, tau}) do
    ((tau + t - (tat - now)) / t)
    |> max(0.0)
    |> min(requests * 1.0)
  end

  # Time until the next token is available (ms, rounded up).
  defp wait_ms(tat, now, tau), do: div(tat - tau - now + 999, 1000)

  defp rate_limiting_enabled?(config) do
    HTTPower.Config.enabled?(config, :rate_limit, false)
  end

  # Public-facing helper (loads config from Application.get_env)
  defp get_strategy(config) when is_list(config) do
    get_strategy(config, @default_config)
  end

  # Optimized version for GenServer callbacks (uses cached default_config)
  defp get_strategy(config, default_config) do
    Keyword.get(config, :strategy) ||
      Keyword.get(default_config, :strategy, :wait)
  end

  # Public-facing helper (loads config from Application.get_env)
  defp get_max_wait_time(config) when is_list(config) do
    get_max_wait_time(config, @default_config)
  end

  # Optimized version for GenServer callbacks (uses cached default_config)
  defp get_max_wait_time(config, default_config) do
    Keyword.get(config, :max_wait_time) ||
      Keyword.get(default_config, :max_wait_time, 5000)
  end

  defp handle_rate_limit_exceeded(:error, _wait_time_ms, _config, bucket_key) do
    :telemetry.execute(
      [:httpower, :rate_limit, :exceeded],
      %{tokens_remaining: 0},
      %{bucket_key: bucket_key, strategy: :error}
    )

    {:error, :too_many_requests}
  end

  defp handle_rate_limit_exceeded(:wait, wait_time_ms, config, bucket_key) do
    max_wait_time = get_max_wait_time(config)
    wait_and_retry(:wait, wait_time_ms, config, bucket_key, max_wait_time, 0)
  end

  defp wait_and_retry(:wait, wait_time_ms, config, bucket_key, max_wait_time, total_waited) do
    if total_waited + wait_time_ms <= max_wait_time do
      :telemetry.execute(
        [:httpower, :rate_limit, :wait],
        %{wait_time_ms: wait_time_ms},
        %{bucket_key: bucket_key, strategy: :wait}
      )

      :timer.sleep(wait_time_ms)

      # Re-check and consume after waiting — another request may have
      # consumed the token that refilled during our sleep
      case do_consume(bucket_key, gcra_params(config)) do
        {:ok, _remaining} ->
          :ok

        {:error, :too_many_requests, new_wait_time_ms} ->
          wait_and_retry(
            :wait,
            new_wait_time_ms,
            config,
            bucket_key,
            max_wait_time,
            total_waited + wait_time_ms
          )
      end
    else
      Logger.warning("Rate limit total wait time would exceed max_wait_time (#{max_wait_time}ms)")

      {:error, :rate_limit_wait_timeout}
    end
  end

  defp cleanup_old_buckets do
    cutoff_us = now_us() - @bucket_ttl * 1000

    :ets.select_delete(@table_name, [
      # Idle GCRA bucket rows: {bucket_key, tat} with an integer TAT past the TTL.
      {{:"$1", :"$2"}, [{:is_integer, :"$2"}, {:<, :"$2", cutoff_us}], [true]},
      # Idle adaptive-state rows: {{:adaptive_state, key}, state, touched_us} not
      # refreshed within the TTL — the circuit went quiet without recovering, so
      # nothing cleared the row. Without this they would leak forever.
      {{:"$1", :"$2", :"$3"}, [{:<, :"$3", cutoff_us}], [true]}
    ])
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  # Adaptive rate limiting based on circuit breaker health
  defp maybe_adjust_rate_for_circuit_state(config, request) do
    # Only adjust if adaptive mode is enabled (default: true)
    if Keyword.get(config, :adaptive, true) do
      circuit_key =
        Keyword.get(config, :circuit_breaker_key) ||
          Keyword.get(request.opts, :circuit_breaker_key) ||
          request.url.host

      # Query circuit breaker state (read-only, loose coupling)
      circuit_state = CircuitBreaker.get_state(circuit_key)

      adjust_rate_for_circuit(config, circuit_state, circuit_key)
    else
      config
    end
  end

  defp adjust_rate_for_circuit(config, nil, circuit_key) do
    # Circuit breaker not initialized yet, use normal rate
    clear_adaptive_state(circuit_key)
    config
  end

  defp adjust_rate_for_circuit(config, :closed, circuit_key) do
    # Service healthy - use full rate (100%)
    clear_adaptive_state(circuit_key)
    config
  end

  defp adjust_rate_for_circuit(config, :half_open, circuit_key) do
    # Service recovering - be conservative (50% of normal rate)
    original_requests = Keyword.get(config, :requests, 100)
    adjusted_requests = max(1, div(original_requests, 2))

    maybe_emit_adaptive_telemetry(
      circuit_key,
      :half_open,
      original_requests,
      adjusted_requests,
      0.5
    )

    Keyword.put(config, :requests, adjusted_requests)
  end

  defp adjust_rate_for_circuit(config, :open, circuit_key) do
    # Service down - minimal rate for health checks (10%)
    original_requests = Keyword.get(config, :requests, 100)
    adjusted_requests = max(1, div(original_requests, 10))

    maybe_emit_adaptive_telemetry(circuit_key, :open, original_requests, adjusted_requests, 0.1)

    Keyword.put(config, :requests, adjusted_requests)
  end

  defp clear_adaptive_state(circuit_key) do
    :ets.delete(@table_name, {:adaptive_state, circuit_key})
  end

  # Only emit telemetry when the adaptive state changes, not on every request
  defp maybe_emit_adaptive_telemetry(
         circuit_key,
         circuit_state,
         original_rate,
         adjusted_rate,
         reduction_factor
       ) do
    adaptive_key = {:adaptive_state, circuit_key}

    already_recorded? =
      match?([{^adaptive_key, ^circuit_state, _ts}], :ets.lookup(@table_name, adaptive_key))

    # Refresh the row (and its timestamp) on every degraded observation so an
    # actively-degraded circuit stays alive; the timestamp lets periodic cleanup
    # reap it once traffic stops without the circuit recovering.
    :ets.insert(@table_name, {adaptive_key, circuit_state, now_us()})

    unless already_recorded? do
      :telemetry.execute(
        [:httpower, :rate_limit, :adaptive_reduction],
        %{
          original_rate: original_rate,
          adjusted_rate: adjusted_rate,
          reduction_factor: reduction_factor
        },
        %{
          circuit_key: circuit_key,
          circuit_state: circuit_state,
          coordination: :circuit_breaker_adaptive
        }
      )
    end
  end
end

defmodule HTTPower.Profiles do
  @moduledoc """
  Pre-configured profiles for common HTTPower use cases.

  Profiles encode best practices for middleware coordination, providing
  optimal settings for different scenarios out of the box.

  ## Available Profiles

  - `:payment_processing` - Conservative settings for payment gateways and financial APIs
  - `:high_volume_api` - High-throughput settings for APIs that handle large request volumes
  - `:microservices_mesh` - Optimized for microservices inter-service communication

  ## Usage

      # Use a profile when creating a client
      client = HTTPower.new(
        base_url: "https://payment-gateway.com",
        profile: :payment_processing
      )

      # Profile settings are merged with explicit options (explicit wins)
      client = HTTPower.new(
        base_url: "https://api.example.com",
        profile: :high_volume_api,
        rate_limit: [requests: 2000]  # Override profile's rate limit
      )

  ## Profile Details

  ### :payment_processing

  Optimized for payment gateways (Stripe, PayPal, etc.) where reliability
  and correctness are more important than speed.

  - **Rate limiting:** Conservative (100 req/min), adaptive based on circuit health
  - **Circuit breaker:** Aggressive (30% failure threshold), long timeout for slow payment APIs
  - **Deduplication:** Enabled with 5s window to prevent double charges
  - **Retry:** 3 attempts with longer delays (payment APIs are slow)

  **Key benefit:** Prevents double charges and duplicate orders automatically.

  ### :high_volume_api

  Optimized for public APIs or internal services that need to handle
  high request volumes efficiently.

  - **Rate limiting:** High throughput (1000 req/min), adaptive
  - **Circuit breaker:** More tolerant (50% failure threshold), fast recovery
  - **Deduplication:** Short window (1s), response sharing across concurrent requests
  - **Retry:** Fewer attempts (2x) with fast delays

  **Key benefit:** Maximum throughput with dedup providing 5x capacity boost.

  ### :microservices_mesh

  Optimized for microservices calling each other in a service mesh.

  - **Rate limiting:** Moderate (500 req/min), adaptive
  - **Circuit breaker:** Balanced (40% threshold), signals rate limiter
  - **Deduplication:** Critical for retry storms, 2s window
  - **Retry:** Standard retries with moderate delays

  **Key benefit:** Prevents cascade failures and retry storms between services.
  """

  @doc """
  Returns configuration for payment processing use cases.

  Best for: Stripe, PayPal, payment gateways, financial APIs.
  Priority: Correctness > Speed
  """
  @spec payment_processing() :: keyword()
  def payment_processing do
    [
      # Adaptive rate limiting - reduces when service is struggling
      rate_limit: [
        enabled: true,
        requests: 100,
        per: :minute,
        strategy: :wait,
        max_wait_time: 5000,
        adaptive: true
      ],

      # Aggressive circuit breaker - payment APIs must be reliable
      circuit_breaker: [
        enabled: true,
        failure_threshold_percentage: 30.0,
        window_size: 20,
        timeout: 30_000,
        half_open_requests: 3
      ],

      # Deduplication critical - prevent double charges
      deduplicate: [
        enabled: true,
        ttl: 5_000
      ],

      # Conservative retry for slow payment gateways
      max_retries: 3,
      base_delay: 2_000,
      max_delay: 30_000
    ]
  end

  @doc """
  Returns configuration for high-volume API use cases.

  Best for: Public APIs, high-traffic internal services, content APIs.
  Priority: Throughput > Latency
  """
  @spec high_volume_api() :: keyword()
  def high_volume_api do
    [
      # High-throughput rate limiting
      rate_limit: [
        enabled: true,
        requests: 1000,
        per: :minute,
        strategy: :wait,
        max_wait_time: 5000,
        adaptive: true
      ],

      # Tolerant circuit breaker - expect some failures at high volume
      circuit_breaker: [
        enabled: true,
        failure_threshold_percentage: 50.0,
        window_size: 100,
        timeout: 5_000,
        half_open_requests: 10
      ],

      # Short dedup window, share responses across concurrent requests
      deduplicate: [
        enabled: true,
        ttl: 1_000
      ],

      # Fast retries for quick recovery
      max_retries: 2,
      base_delay: 500,
      max_delay: 10_000
    ]
  end

  @doc """
  Returns configuration for microservices mesh use cases.

  Best for: Service-to-service calls, internal microservices, Kubernetes.
  Priority: Reliability > Individual Request Speed
  """
  @spec microservices_mesh() :: keyword()
  def microservices_mesh do
    [
      # Moderate rate limiting with adaptive behavior
      rate_limit: [
        enabled: true,
        requests: 500,
        per: :minute,
        strategy: :wait,
        max_wait_time: 5000,
        adaptive: true
      ],

      # Balanced circuit breaker - protect against cascades
      circuit_breaker: [
        enabled: true,
        failure_threshold_percentage: 40.0,
        window_size: 50,
        timeout: 10_000,
        half_open_requests: 5
      ],

      # Dedup critical for retry storms in mesh
      deduplicate: [
        enabled: true,
        ttl: 2_000
      ],

      # Standard retry with moderate delays
      max_retries: 3,
      base_delay: 1_000,
      max_delay: 20_000
    ]
  end

  @doc """
  Gets a profile by name.

  Returns `{:ok, config}` for valid profiles, `{:error, :unknown_profile}` otherwise.

  ## Examples

      iex> HTTPower.Profiles.get(:payment_processing)
      {:ok, [rate_limit: [...], circuit_breaker: [...], ...]}

      iex> HTTPower.Profiles.get(:invalid)
      {:error, :unknown_profile}
  """
  @spec get(atom()) :: {:ok, keyword()} | {:error, :unknown_profile}
  def get(:payment_processing), do: {:ok, payment_processing()}
  def get(:high_volume_api), do: {:ok, high_volume_api()}
  def get(:microservices_mesh), do: {:ok, microservices_mesh()}
  def get(_), do: {:error, :unknown_profile}

  @doc """
  Lists all available profile names.

  ## Examples

      iex> HTTPower.Profiles.list()
      [:payment_processing, :high_volume_api, :microservices_mesh]
  """
  @spec list() :: [atom()]
  def list do
    [:payment_processing, :high_volume_api, :microservices_mesh]
  end
end

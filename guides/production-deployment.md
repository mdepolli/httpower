# Production Deployment Guide

This guide covers deploying HTTPower in production environments with proper configuration, monitoring, and best practices.

## Application Supervision Tree

HTTPower starts a supervision tree automatically when added to your application. The supervision tree manages two GenServers:

- `HTTPower.RateLimiter` - Manages rate limiting state in ETS
- `HTTPower.CircuitBreaker` - Manages circuit breaker state in ETS

### Automatic Startup

When you add HTTPower to your `mix.exs`, the supervision tree starts automatically:

```elixir
# mix.exs
def application do
  [
    mod: {MyApp.Application, []},
    extra_applications: [:logger]
  ]
end

def deps do
  [
    {:httpower, "~> 0.5.0"}
  ]
end
```

The `HTTPower.Application` module is configured in HTTPower's `mix.exs`:

```elixir
# HTTPower's mix.exs (for reference - you don't need to change this)
def application do
  [
    mod: {HTTPower.Application, []}
  ]
end
```

### Supervision Tree Structure

```
YourApp.Supervisor
├── HTTPower.Supervisor (one_for_one strategy)
│   ├── HTTPower.RateLimiter (GenServer with ETS)
│   └── HTTPower.CircuitBreaker (GenServer with ETS)
└── Your other children...
```

The `one_for_one` strategy means if a GenServer crashes, only that process is restarted - not the entire HTTPower supervision tree.

### Verifying Supervision

Check that HTTPower's processes are running:

```elixir
# In IEx
iex> Process.whereis(HTTPower.RateLimiter)
#PID<0.234.0>

iex> Process.whereis(HTTPower.CircuitBreaker)
#PID<0.235.0>

# Check supervisor
iex> Supervisor.which_children(HTTPower.Supervisor)
[
  {HTTPower.CircuitBreaker, #PID<0.235.0>, :worker, [HTTPower.CircuitBreaker]},
  {HTTPower.RateLimiter, #PID<0.234.0>, :worker, [HTTPower.RateLimiter]}
]
```

## Production Configuration

### Recommended prod.exs

```elixir
# config/prod.exs
config :httpower,
  # Retry Configuration
  max_retries: 3,
  retry_safe: false,          # Only enable for idempotent operations
  base_delay: 1000,
  max_delay: 30_000,

  # Circuit Breaker
  circuit_breaker: [
    enabled: true,
    failure_threshold: 5,
    window_size: 10,
    timeout: 60_000,           # 60 seconds before half-open
    half_open_requests: 1
  ],

  # Rate Limiting
  rate_limit: [
    enabled: true,
    requests: 100,
    per: :minute,
    strategy: :wait,
    max_wait_time: 5000        # Max 5 second wait
  ],

  # Logging
  logging: [
    enabled: true,
    level: :info,              # Use :info in production
    sanitize_headers: ["authorization", "api-key", "x-api-key", "cookie"],
    sanitize_body_fields: [
      "password", "secret", "token",
      "credit_card", "card_number", "cvv", "cvc",
      "ssn", "tax_id"
    ]
  ]
```

### Per-Service Configuration

For applications calling multiple external services:

```elixir
# config/prod.exs
config :myapp, :stripe_client,
  circuit_breaker: [
    failure_threshold: 3,
    timeout: 30_000
  ],
  rate_limit: [
    requests: 100,
    per: :second
  ]

config :myapp, :github_client,
  circuit_breaker: [
    failure_threshold: 5,
    timeout: 60_000
  ],
  rate_limit: [
    requests: 60,
    per: :minute
  ]

# In your code
defmodule MyApp.StripeClient do
  def client do
    config = Application.get_env(:myapp, :stripe_client, [])

    HTTPower.new([
      base_url: "https://api.stripe.com",
      circuit_breaker_key: "stripe"
    ] ++ config)
  end
end
```

## Environment Variables

Use environment variables for secrets and environment-specific values:

```elixir
# config/runtime.exs (Elixir 1.11+)
import Config

if config_env() == :prod do
  config :myapp, :api_client,
    base_url: System.get_env("API_BASE_URL") || "https://api.example.com",
    api_key: System.fetch_env!("API_KEY"),
    timeout: String.to_integer(System.get_env("API_TIMEOUT", "30")),
    max_retries: String.to_integer(System.get_env("API_MAX_RETRIES", "3"))
end
```

## Monitoring

### Circuit Breaker State

Monitor circuit breaker state changes in production:

```elixir
defmodule MyApp.CircuitBreakerMonitor do
  require Logger

  def check_circuits do
    circuits = ["payment_api", "user_service", "order_service"]

    Enum.each(circuits, fn circuit_key ->
      state = HTTPower.CircuitBreaker.get_state(circuit_key)

      case state do
        :open -> Logger.warning("Circuit OPEN: #{circuit_key}")
        :half_open -> Logger.info("Circuit HALF-OPEN: #{circuit_key}")
        :closed -> :ok
        nil -> :ok  # Circuit not initialized yet
      end
    end)
  end
end

# Run periodically
# Schedule with Quantum, Oban, or GenServer
```

### Rate Limiter Metrics

Track rate limiting hits:

```elixir
defmodule MyApp.RateLimitMonitor do
  def track_rate_limit_result(result) do
    case result do
      {:error, %{reason: :rate_limit_exceeded}} ->
        :telemetry.execute(
          [:myapp, :http, :rate_limit_exceeded],
          %{count: 1},
          %{}
        )
      _ ->
        :ok
    end
  end
end

# Wrap your API calls
def fetch_data do
  result = HTTPower.get(client(), "/data")
  MyApp.RateLimitMonitor.track_rate_limit_result(result)
  result
end
```

### Request Duration Tracking

HTTPower logs request duration automatically. Parse logs or use Telemetry:

```elixir
# HTTPower logs include duration:
# [info] [HTTPower] [req_abc123] ← 200 (1234ms)
```

## Performance Tuning

### ETS Table Sizing

HTTPower uses ETS for rate limiter and circuit breaker state. For high-volume applications:

```elixir
# ETS tables are created with these defaults:
# - :set type (key-value storage)
# - :public read_concurrency
# - Named tables

# No tuning needed for most applications
# ETS handles millions of operations per second
```

### Connection Pooling

Connection pooling is handled by the underlying adapter (Req/Finch or Tesla):

**For Req (default):**
Finch manages connection pooling automatically. Configure if needed:

```elixir
# config/config.exs
config :req, finch: [
  pools: %{
    default: [size: 25, count: 5]
  ]
]
```

**For Tesla:**
Configure your Tesla adapter's connection pool (Finch, Hackney, etc.).

### Timeout Strategy

Set appropriate timeouts for your use case:

```elixir
# Fast APIs
config :httpower, timeout: 10

# Slow APIs or large payloads
config :httpower, timeout: 120

# Per-request override for specific slow endpoints
HTTPower.get(slow_endpoint, timeout: 300)
```

## High Availability Setup

### Multi-Node Considerations

HTTPower's rate limiter and circuit breaker are **per-node** (stored in local ETS). In a multi-node setup:

**Rate Limiting:**
- Each node has its own rate limit buckets
- Total throughput = `requests_per_node * num_nodes`
- Example: 100 req/min × 3 nodes = 300 req/min total

**Circuit Breaker:**
- Each node has independent circuit state
- Circuit opens independently on each node
- This is usually desired behavior (node-level isolation)

### Centralized Rate Limiting (Advanced)

For strict global rate limits across multiple nodes, implement a centralized rate limiter using Redis or a distributed state library. HTTPower's built-in rate limiter is designed for per-node limits.

### Load Balancer Configuration

When using HTTPower behind a load balancer:

```elixir
config :httpower,
  # Ensure reasonable timeouts
  timeout: 30,

  # Circuit breaker per-node is fine
  circuit_breaker: [enabled: true],

  # Rate limiting is per-node
  rate_limit: [
    enabled: true,
    requests: 50  # If 2 nodes, total is ~100 req/min
  ]
```

## Security Best Practices

### 1. SSL Verification

Always enable SSL verification in production:

```elixir
config :httpower, ssl_verify: true  # Default
```

### 2. Sensitive Data Logging

Configure comprehensive sanitization:

```elixir
config :httpower,
  logging: [
    sanitize_headers: [
      "authorization", "api-key", "x-api-key",
      "cookie", "set-cookie", "x-auth-token"
    ],
    sanitize_body_fields: [
      # Auth
      "password", "secret", "token", "api_key",
      # Financial
      "credit_card", "card_number", "cvv", "cvc",
      "account_number", "routing_number",
      # Personal
      "ssn", "tax_id", "drivers_license"
    ]
  ]
```

### 3. API Keys

Store API keys securely:

```elixir
# Use environment variables
api_key = System.fetch_env!("STRIPE_API_KEY")

client = HTTPower.new(
  headers: %{"authorization" => "Bearer #{api_key}"}
)

# Or use runtime.exs
# config/runtime.exs
config :myapp, :stripe_api_key, System.fetch_env!("STRIPE_API_KEY")
```

### 4. Test Mode in Production

**Never enable test mode in production:**

```elixir
# config/prod.exs
config :httpower, test_mode: false  # Default

# Only in test.exs
# config/test.exs
config :httpower, test_mode: true
```

## Deployment Checklist

Before deploying to production:

- [ ] Configure circuit breaker thresholds based on your SLAs
- [ ] Set appropriate rate limits for each external service
- [ ] Configure PCI-compliant logging with proper sanitization
- [ ] Set reasonable retry limits and timeouts
- [ ] Test circuit breaker behavior under failure scenarios
- [ ] Verify test mode is disabled in production config
- [ ] Set up monitoring for circuit breaker state changes
- [ ] Document which endpoints use which circuit breaker keys
- [ ] Configure environment variables for API keys
- [ ] Test fallback behavior when circuits are open
- [ ] Set up alerts for rate limit exceeded errors
- [ ] Verify SSL verification is enabled
- [ ] Test graceful degradation scenarios

## Graceful Degradation

Handle circuit breaker opens gracefully:

```elixir
defmodule MyApp.PaymentService do
  def charge_customer(amount) do
    case HTTPower.post(payment_client(), "/charge", body: amount) do
      {:ok, response} ->
        {:ok, response}

      {:error, %{reason: :circuit_breaker_open}} ->
        # Circuit is open - payment service is down
        Logger.error("Payment service unavailable (circuit open)")
        {:error, :service_unavailable}

      {:error, %{reason: :rate_limit_exceeded}} ->
        # Hit rate limit
        Logger.warning("Payment service rate limited")
        {:error, :rate_limited}

      {:error, error} ->
        {:error, error}
    end
  end

  # Fallback method
  def charge_customer_fallback(amount) do
    # Use secondary payment processor
    # Queue for later processing
    # Return friendly error to user
  end
end
```

## Troubleshooting Production Issues

### Issue: Circuit keeps opening

**Debug:**
```elixir
# Check current state
HTTPower.CircuitBreaker.get_state("my_service")

# Temporarily disable to test
config :httpower, circuit_breaker: [enabled: false]

# Check failure patterns in logs
# Look for: [HTTPower] [req_*] ← 500 or ← timeout
```

**Solutions:**
- Increase `failure_threshold` if service has transient issues
- Increase `window_size` to smooth out spikes
- Reduce `timeout` if service is responding slowly
- Check if external service is actually down

### Issue: Rate limiting too aggressive

**Debug:**
```elixir
# Check rate limit config
Application.get_env(:httpower, :rate_limit)

# Test without rate limiting
config :httpower, rate_limit: [enabled: false]
```

**Solutions:**
- Increase `requests` or change `per` to larger window
- Use `:error` strategy instead of `:wait`
- Use custom `rate_limit_key` to separate endpoints
- Implement per-user rate limiting in your app layer

### Issue: High memory usage

**Check ETS tables:**
```elixir
:ets.info(:httpower_rate_limiter)
:ets.info(:httpower_circuit_breaker)
```

**Solutions:**
- Rate limiter has automatic cleanup (5 min inactive buckets)
- Circuit breaker tracks only last `window_size` requests
- Memory usage should be minimal (<10MB typically)

## Next Steps

- Read [Configuration Reference](configuration-reference.md) for all options
- See [Migrating from Tesla](migrating-from-tesla.md) or [Migrating from Req](migrating-from-req.md)
- Review `guides/examples/` for code patterns
- Monitor production logs for HTTPower messages

## Getting Help

Production issues:
1. Check logs for [HTTPower] messages with correlation IDs
2. Review circuit breaker and rate limit state
3. Review configuration reference and deployment guide
4. Open an issue with logs and config: https://github.com/mdepolli/httpower/issues

# HTTPower ⚡

Production reliability for your Elixir HTTP client. HTTPower adds circuit breakers, rate limiting, request deduplication, smart retries, and PCI-compliant logging to Finch, Req, or Tesla.

[![Hex.pm](https://img.shields.io/hexpm/v/httpower)](https://hex.pm/packages/httpower)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue)](https://hexdocs.pm/httpower)
[![CI](https://github.com/mdepolli/httpower/actions/workflows/ci.yml/badge.svg?branch=master)](https://github.com/mdepolli/httpower/actions/workflows/ci.yml)

```elixir
stripe = HTTPower.new(
  adapter: :req,
  base_url: "https://api.stripe.com",
  headers: %{"authorization" => "Bearer #{api_key}"},
  rate_limit: [requests: 100, per: :second],
  circuit_breaker: [failure_threshold: 5, timeout: 30_000],
  deduplicate: true
)

{:ok, response} = HTTPower.post(stripe, "/v1/charges",
  json: %{amount: 2000, currency: "usd"}
)
```

All reliability features work identically across adapters — switch from Req to Finch without changing anything else.

## Features

- **Circuit breaker** — automatic failure detection with closed/open/half-open states
- **Rate limiting** — token bucket algorithm with adaptive reduction during outages
- **Request deduplication** — concurrent identical requests share a single HTTP call
- **Smart retries** — exponential backoff with jitter, respects Retry-After headers
- **PCI-compliant logging** — automatic sanitization of cards, tokens, and credentials
- **Telemetry** — events for every reliability feature, ready for Prometheus/OpenTelemetry
- **Correlation IDs** — unique request tracing across services
- **Body encoding/decoding** — `json:` and `form:` options with Content-Type-driven response decoding
- **Never raises** — always returns `{:ok, response}` or `{:error, error}`

## Table of Contents

- [Quick Start](#quick-start)
- [Error Handling](#error-handling)
- [Test Mode](#test-mode)
- [Rate Limiting](#rate-limiting)
- [Circuit Breaker](#circuit-breaker)
- [Request Deduplication](#request-deduplication)
- [PCI-Compliant Logging](#pci-compliant-logging)
- [Observability & Telemetry](#observability--telemetry)
- [Development](#development)
- [License](#license)

## Quick Start

### Installation

Add `httpower` and your HTTP client of choice to `mix.exs`:

```elixir
def deps do
  [
    {:httpower, "~> 0.22.0"},

    # Pick one (or more):
    {:finch, ">= 0.19.0"},     # High performance (default)
    {:req, ">= 0.4.0"},        # Batteries-included
    {:tesla, ">= 1.10.0"}      # If you already use Tesla
  ]
end
```

### Basic Usage

Create a client with the reliability features you need:

```elixir
github = HTTPower.new(
  adapter: :req,
  base_url: "https://api.github.com",
  headers: %{"authorization" => "Bearer #{token}"},
  rate_limit: [requests: 60, per: :minute],
  circuit_breaker: [failure_threshold: 5, timeout: 30_000],
  max_retries: 3
)

{:ok, repos} = HTTPower.get(github, "/user/repos")
{:ok, repo} = HTTPower.get(github, "/repos/owner/name")
{:ok, issue} = HTTPower.post(github, "/repos/owner/name/issues",
  json: %{title: "Bug report", body: "Details..."}
)
```

Or make one-off requests without a client:

```elixir
{:ok, response} = HTTPower.get("https://api.example.com/users")
{:ok, response} = HTTPower.post("https://api.example.com/users",
  json: %{name: "John", email: "john@example.com"}
)
```

JSON responses are decoded automatically. Use `raw: true` to skip decoding.

### Adapters

HTTPower wraps your existing HTTP client — Finch, Req, or Tesla. If multiple are installed, Finch is used by default. Override with `adapter: :req` or `adapter: :tesla`.

For existing Tesla or Req applications, see [Migrating from Tesla](guides/migrating-from-tesla.md) or [Migrating from Req](guides/migrating-from-req.md).

### Global Configuration

```elixir
# config/config.exs
config :httpower,
  adapter: HTTPower.Adapter.Req,
  max_retries: 3,
  rate_limit: [enabled: true, requests: 100, per: :minute, strategy: :wait],
  circuit_breaker: [enabled: true, failure_threshold: 5, timeout: 60_000]

config :httpower, :logging,
  level: :info,
  log_headers: true,
  log_body: true
```

Per-request options override per-client options, which override global config.

## Error Handling

HTTPower never raises — all operations return `{:ok, response}` or `{:error, error}`:

```elixir
case HTTPower.get("https://api.example.com") do
  {:ok, %HTTPower.Response{status: 200, body: body}} ->
    process_data(body)

  {:ok, %HTTPower.Response{status: 404}} ->
    handle_not_found()

  {:error, %HTTPower.Error{reason: :timeout}} ->
    handle_timeout()

  {:error, %HTTPower.Error{reason: :service_unavailable}} ->
    # Circuit breaker is open
    use_fallback()

  {:error, %HTTPower.Error{reason: :too_many_requests}} ->
    # Rate limit exceeded (with :error strategy)
    back_off()
end
```

## Test Mode

HTTPower can block all real HTTP requests during testing:

```elixir
# In test_helper.exs
Application.put_env(:httpower, :test_mode, true)

# In your tests
defmodule MyAppTest do
  use ExUnit.Case

  setup do
    HTTPower.Test.setup()
  end

  test "API integration with mocking" do
    # Use HTTPower.Test for adapter-agnostic mocking
    HTTPower.Test.stub(fn conn ->
      HTTPower.Test.json(conn, %{status: "success"})
    end)

    {:ok, response} = HTTPower.get("https://api.example.com/test")
    assert response.body == %{"status" => "success"}
  end

  test "real requests are blocked" do
    # Requests without mocks are blocked in test mode
    {:error, error} = HTTPower.get("https://real-api.com")
    assert error.reason == :network_blocked
  end
end
```

## PCI-Compliant Logging

HTTPower provides opt-in telemetry-based logging with automatic PCI-compliant data sanitization and **structured metadata** for log aggregation systems. Simply attach the logger to start logging all HTTP requests and responses.

### Quick Start

```elixir
# In your application.ex
def start(_type, _args) do
  # Attach the logger to enable logging
  HTTPower.Logger.attach()

  # ... rest of your supervision tree
end
```

Now all HTTP requests will be logged with automatic sanitization and structured metadata:

```elixir
HTTPower.get("https://api.example.com/users",
  headers: %{"Authorization" => "Bearer secret-token"}
)
# Logs:
# [HTTPower] [req_a1b2c3...] → GET https://api.example.com/users headers=%{"authorization" => "[REDACTED]"}
# [HTTPower] [req_a1b2c3...] ← 200 (45ms) body=%{"users" => [...]}
```

### Structured Logging with Metadata

All log entries include machine-readable metadata via `Logger.metadata()`, enabling powerful querying in log aggregation systems like Datadog, Splunk, ELK, or Loki:

```elixir
# Query slow requests
httpower_duration_ms:>1000

# Find all 5xx errors
httpower_status:>=500

# Trace a specific request
httpower_correlation_id:"req_abc123"

# Filter by HTTP method
httpower_method:post
```

**Available metadata:**

- `httpower_correlation_id` - Unique request identifier
- `httpower_event` - Event type (`:request`, `:response`, `:exception`)
- `httpower_method` - HTTP method (`:get`, `:post`, etc.)
- `httpower_url` - Request URL
- `httpower_status` - HTTP status code (responses only)
- `httpower_duration_ms` - Request duration in milliseconds (responses only)
- `httpower_headers` / `httpower_response_headers` - Sanitized headers (if enabled)
- `httpower_body` / `httpower_response_body` - Sanitized body (if enabled)

All metadata respects your logging configuration and sanitizes sensitive data automatically.

### Automatic Sanitization

Sensitive data is automatically redacted from logs:

```elixir
# Authorization headers are sanitized
HTTPower.get("https://api.example.com/users",
  headers: %{"Authorization" => "Bearer secret-token"}
)
# Logs: headers=%{"authorization" => "[REDACTED]"}

# Credit card numbers are sanitized
HTTPower.post("https://payment-api.com/charge",
  body: ~s({"card": "4111111111111111", "amount": 100})
)
# Logs: body={"card": "[REDACTED]", "amount": 100}
```

### What Gets Sanitized

**Headers:**

- Authorization, API-Key, X-API-Key, Token, Cookie, Secret

**Body Fields:**

- password, api_key, token, credit_card, cvv, ssn, pin

**Patterns:**

- Credit card numbers (13-19 digits)
- CVV codes (3-4 digits)

### Configuration

Configure logging via `attach/1` options or Application config:

```elixir
# Runtime configuration (recommended)
HTTPower.Logger.attach(
  level: :debug,
  log_headers: true,
  log_body: true,
  sanitize_headers: ["x-custom-token"],     # Additional headers to sanitize
  sanitize_body_fields: ["secret_key"]      # Additional body fields to sanitize
)

# Or use Application config (applies when using attach/0)
config :httpower, :logging,
  level: :info,
  log_headers: true,
  log_body: true

# Sanitization rules live under a separate :sanitization key
# (shared by telemetry redaction and the logger)
config :httpower, :sanitization,
  sanitize_headers: ["x-custom-token"],
  sanitize_body_fields: ["secret_key"]
```

**Important:** Custom sanitization fields are **additive** - they supplement the defaults, not replace them.

### Disabling Logging

To disable logging, simply don't attach the logger, or detach it:

```elixir
# Don't attach in application.ex
# HTTPower.Logger.attach()  # Commented out

# Or detach programmatically
HTTPower.Logger.detach()
```

## Correlation IDs

Every request gets a unique correlation ID for distributed tracing and request tracking:

```elixir
# Example log output:
[HTTPower] [req_a1b2c3d4e5f6g7h8] → GET https://api.example.com/users
[HTTPower] [req_a1b2c3d4e5f6g7h8] ← 200 (245ms) body=%{"users" => [...]}
```

Correlation IDs help you:

- Track requests across services and logs
- Correlate requests with their responses
- Debug production issues with distributed tracing
- Analyze request flows in microservices

The correlation ID format is `req_` followed by 16 hexadecimal characters, ensuring uniqueness across requests.

## Rate Limiting

HTTPower includes built-in rate limiting using a token bucket algorithm to prevent overwhelming APIs and respect rate limits.

### Token Bucket Algorithm

The token bucket algorithm works by:

1. Each API endpoint has a bucket with a maximum capacity of tokens
2. Capacity refills continuously at a fixed rate (e.g., 100 requests per minute)
3. Each request consumes one token
4. If no tokens are available, the request either waits or returns an error

> Internally this is implemented with the GCRA (Generic Cell Rate Algorithm) formulation —
> a single timestamp per bucket rather than a stored token count — which keeps the hot path
> lock-free. The token-bucket semantics above are preserved exactly.

### Basic Usage

```elixir
# Global rate limiting configuration
config :httpower, :rate_limit,
  enabled: true,
  requests: 100,        # Max 100 requests
  per: :minute,         # Per minute
  strategy: :wait       # Wait for tokens (or :error to fail immediately)

# All requests automatically respect rate limits
HTTPower.get("https://api.example.com/users")
```

### Per-Client Rate Limiting

```elixir
# Configure rate limits per client
github_client = HTTPower.new(
  base_url: "https://api.github.com",
  rate_limit: [requests: 60, per: :minute]
)

# This client respects GitHub's 60 req/min limit
HTTPower.get(github_client, "/users")
```

### Per-Request Configuration

```elixir
# Override rate limit for specific requests
HTTPower.get("https://api.example.com/search",
  rate_limit: [
    requests: 10,
    per: :minute,
    strategy: :error  # Return error instead of waiting
  ]
)
```

### Custom Bucket Keys

```elixir
# Use custom keys to group requests
HTTPower.get("https://api.example.com/endpoint1",
  rate_limit_key: "example_api",
  rate_limit: [requests: 100, per: :minute]
)

HTTPower.get("https://api.example.com/endpoint2",
  rate_limit_key: "example_api",  # Shares same rate limit
  rate_limit: [requests: 100, per: :minute]
)
```

### Strategies

**`:wait` Strategy** (default)

- Waits until tokens are available (up to `max_wait_time`)
- Ensures requests eventually succeed
- Good for background jobs

```elixir
config :httpower, :rate_limit,
  strategy: :wait,
  max_wait_time: 5000  # Wait up to 5 seconds
```

**`:error` Strategy**

- Returns `{:error, :too_many_requests}` immediately
- Lets your application decide how to handle rate limits
- Good for user-facing requests

```elixir
case HTTPower.get(url, rate_limit: [strategy: :error]) do
  {:ok, response} -> handle_success(response)
  {:error, %{reason: :too_many_requests}} -> handle_rate_limit()
  {:error, error} -> handle_error(error)
end
```

### Rate Limit Headers Parsing

HTTPower can automatically parse rate limit information from HTTP response headers and synchronize with the local rate limiter:

```elixir
# Parse rate limit headers from response
headers = %{
  "x-ratelimit-limit" => "60",
  "x-ratelimit-remaining" => "42",
  "x-ratelimit-reset" => "1234567890"
}

{:ok, rate_limit_info} = HTTPower.RateLimitHeaders.parse(headers)
# => %{limit: 60, remaining: 42, reset_at: ~U[2009-02-13 23:31:30Z], format: :github}

# Update rate limiter bucket from server headers (pass the bucket's rate config)
HTTPower.Middleware.RateLimiter.update_from_headers(
  "api.github.com", rate_limit_info, requests: 60, per: :minute
)

# Inspect raw GCRA bucket state (theoretical arrival time, in µs)
HTTPower.Middleware.RateLimiter.get_info("api.github.com")
# => %{tat_us: 1234567890}

# For a human-meaningful "tokens remaining" value, use check_rate_limit/2:
HTTPower.Middleware.RateLimiter.check_rate_limit("api.github.com", requests: 60, per: :minute)
# => {:ok, 42.0}
```

Supported header formats:

- **GitHub/Twitter**: `X-RateLimit-*` headers
- **RFC 6585/IETF**: `RateLimit-*` headers
- **Stripe**: `X-Stripe-RateLimit-*` headers
- **Retry-After**: Integer seconds format (on 429/503 responses)

### Configuration Options

```elixir
config :httpower, :rate_limit,
  enabled: true,              # Enable/disable (default: false)
  requests: 100,              # Max requests per time window
  per: :second,               # Time window: :second, :minute, :hour
  strategy: :wait,            # Strategy: :wait or :error
  max_wait_time: 5000         # Max wait time in ms (default: 5000)
```

### Real-World Examples

```elixir
# GitHub API: 60 requests per minute
github = HTTPower.new(
  base_url: "https://api.github.com",
  rate_limit: [requests: 60, per: :minute]
)

# Stripe API: 100 requests per second
stripe = HTTPower.new(
  base_url: "https://api.stripe.com",
  rate_limit: [requests: 100, per: :second, strategy: :error]
)

# Search endpoints: Lower limits
HTTPower.get("https://api.example.com/search",
  rate_limit: [requests: 10, per: :minute]
)
```

## Circuit Breaker

HTTPower includes circuit breaker pattern implementation to protect your application from cascading failures when calling failing services.

### How Circuit Breakers Work

The circuit breaker has three states:

1. **Closed** (normal operation)
   - Requests pass through normally
   - Failures are tracked in a sliding window
   - Transitions to Open when failure threshold is exceeded

2. **Open** (failing service)
   - Requests fail immediately with `:service_unavailable`
   - No actual service calls are made
   - After a timeout period, transitions to Half-Open

3. **Half-Open** (testing recovery)
   - Limited test requests are allowed through
   - If they succeed, circuit transitions back to Closed
   - If they fail, circuit transitions back to Open

### Basic Usage

```elixir
# Global circuit breaker configuration
config :httpower, :circuit_breaker,
  enabled: true,
  failure_threshold: 5,             # Open after 5 failures
  window_size: 10,                  # Track last 10 requests
  timeout: 60_000,                  # Stay open for 60s
  half_open_requests: 1             # Allow 1 test request in half-open

# All requests automatically use circuit breaker
HTTPower.get("https://api.example.com/users")
```

### Per-Client Circuit Breaker

```elixir
# Configure circuit breaker per client
payment_gateway = HTTPower.new(
  base_url: "https://api.payment-gateway.com",
  circuit_breaker: [
    failure_threshold: 3,
    timeout: 30_000
  ]
)

# This client has its own circuit breaker
HTTPower.post(payment_gateway, "/charge", body: %{amount: 100})
```

### Per-Request Circuit Breaker Key

```elixir
# Use custom keys to group requests
HTTPower.get("https://api.example.com/endpoint1",
  circuit_breaker_key: "example_api"
)

HTTPower.get("https://api.example.com/endpoint2",
  circuit_breaker_key: "example_api"  # Shares same circuit breaker
)
```

### Threshold Strategies

**Absolute Threshold**

```elixir
config :httpower, :circuit_breaker,
  failure_threshold: 5,        # Open after 5 failures
  window_size: 10              # In last 10 requests
```

**Percentage Threshold**

```elixir
config :httpower, :circuit_breaker,
  failure_threshold_percentage: 50,  # Open at 50% failure rate
  window_size: 10                     # Need 10 requests minimum
```

### Manual Control

```elixir
# Manually open a circuit
HTTPower.Middleware.CircuitBreaker.open_circuit("payment_api")

# Manually close a circuit
HTTPower.Middleware.CircuitBreaker.close_circuit("payment_api")

# Reset a circuit completely
HTTPower.Middleware.CircuitBreaker.reset_circuit("payment_api")

# Check circuit state
HTTPower.Middleware.CircuitBreaker.get_state("payment_api")
# Returns: :closed | :open | :half_open | nil
```

### Configuration Options

```elixir
config :httpower, :circuit_breaker,
  enabled: true,                          # Enable/disable (default: false)
  failure_threshold: 5,                   # Failures to trigger open
  failure_threshold_percentage: nil,      # Or use percentage (optional)
  window_size: 10,                        # Sliding window size
  timeout: 60_000,                        # Open state timeout (ms)
  half_open_requests: 1                   # Test requests in half-open
```

### Real-World Examples

**Payment Gateway Protection**

```elixir
# Protect against payment gateway failures
payment = HTTPower.new(
  base_url: "https://api.stripe.com",
  circuit_breaker: [
    failure_threshold: 3,      # Open after 3 failures
    timeout: 30_000,           # Try again after 30s
    half_open_requests: 2      # Test with 2 requests
  ]
)

case HTTPower.post(payment, "/charges", body: charge_data) do
  {:ok, response} ->
    handle_payment(response)

  {:error, %{reason: :service_unavailable}} ->
    # Circuit is open, use fallback payment method
    use_fallback_payment_method()

  {:error, error} ->
    handle_payment_error(error)
end
```

**Cascading Failure Prevention**

```elixir
# After 5 consecutive failures, circuit opens
for _ <- 1..5 do
  {:error, _} = HTTPower.get("https://failing-api.com/endpoint")
end

# Subsequent requests fail immediately (no cascading failures)
{:error, %{reason: :service_unavailable}} =
  HTTPower.get("https://failing-api.com/endpoint")

# After 60 seconds, circuit enters half-open
:timer.sleep(60_000)

# Next successful request closes the circuit
{:ok, _} = HTTPower.get("https://failing-api.com/endpoint")
```

**Combining with Exponential Backoff**

```elixir
# Circuit breaker works with existing retry logic
HTTPower.get("https://api.example.com/users",
  # Retry configuration (transient failures)
  max_retries: 3,
  base_delay: 1000,

  # Circuit breaker (persistent failures)
  circuit_breaker: [
    failure_threshold: 5,
    timeout: 60_000
  ]
)
```

Circuit breaker complements exponential backoff:

- **Exponential backoff**: Handles transient failures (timeouts, temporary errors)
- **Circuit breaker**: Handles persistent failures (service down, deployment issues)
- Together they provide comprehensive failure handling

## Request Deduplication

HTTPower provides in-flight request deduplication to prevent duplicate side effects from double-clicks, race conditions, or concurrent identical requests.

### How Deduplication Works

When deduplication is enabled, HTTPower:

1. **Fingerprints each request** using a hash of method + URL + body
2. **Tracks in-flight requests** - first occurrence executes normally
3. **Duplicate requests wait** - subsequent identical requests wait for the first to complete and receive its response
4. **Auto-cleanup** - tracking data is removed after 500ms

This is **client-side deduplication** that prevents duplicate requests from ever leaving your application.

### Basic Usage

```elixir
# Enable deduplication for a request
HTTPower.post("https://api.example.com/charge",
  body: Jason.encode!(%{amount: 100}),
  deduplicate: true  # Prevents double-clicks from sending duplicate charges
)
```

### Global Configuration

```elixir
# config/config.exs
config :httpower, :deduplicate,
  enabled: true

# All requests now use deduplication
HTTPower.post("https://api.example.com/order", body: order_data)
```

### Custom Deduplication Keys

By default, deduplication uses `method + URL + body` as the fingerprint. You can override this:

```elixir
# Use a custom key (e.g., user action ID)
HTTPower.post("https://api.example.com/charge",
  body: payment_data,
  deduplicate: [
    enabled: true,
    key: "user:#{user_id}:action:#{action_id}"
  ]
)
```

### Use Cases

**Prevent Double-Clicks**

```elixir
def process_payment(user_id, amount) do
  # Even if user clicks "Pay" button multiple times,
  # only one charge request is sent
  HTTPower.post("https://api.payment.com/charge",
    body: Jason.encode!(%{user_id: user_id, amount: amount}),
    deduplicate: true
  )
end
```

**Prevent Race Conditions**

```elixir
# Multiple processes trying to create the same resource
# Only one request executes, others wait and share the response
Task.async(fn ->
  HTTPower.post("/api/users", body: user_data, deduplicate: true)
end)

Task.async(fn ->
  HTTPower.post("/api/users", body: user_data, deduplicate: true)
end)
```

### Deduplication vs Idempotency Keys

**Request Deduplication (Client-Side)**

- Prevents duplicate requests from leaving the client
- Works with any API
- Scope: Single HTTPower instance
- Duration: Very short (seconds)

**Idempotency Keys (Server-Side)**

- Server prevents duplicate processing
- Requires API support
- Scope: Cross-instance, persistent
- Duration: Hours/days

**Best Practice: Use Both**

```elixir
# Generate idempotency key for server-side deduplication
idem_key = UUID.uuid4()

HTTPower.post("/charge",
  headers: %{"Idempotency-Key" => idem_key},  # Server-side
  body: payment_data,
  deduplicate: true,    # Client-side - prevents unnecessary network calls
  max_retries: 3        # Safe to retry with same idem key
)
```

**Defense in Depth:**

- **Client deduplication** = First line of defense (no network call)
- **Idempotency key** = Second line of defense (server deduplication)

## Observability & Telemetry

HTTPower emits comprehensive telemetry events using Elixir's `:telemetry` library for deep observability into HTTP requests, retries, rate limiting, circuit breakers, and deduplication.

### Quick Start

```elixir
:telemetry.attach_many(
  "httpower-handler",
  [
    [:httpower, :request, :start],
    [:httpower, :request, :stop],
    [:httpower, :retry, :attempt]
  ],
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata})
  end,
  nil
)
```

### Available Events

**HTTP Request Lifecycle:**

- `[:httpower, :request, :start]` - Request begins
- `[:httpower, :request, :stop]` - Request completes (includes duration, status, retry_count)
- `[:httpower, :request, :exception]` - Unhandled exception

**Retry Events:**

- `[:httpower, :retry, :attempt]` - Retry attempt (includes attempt_number, delay_ms, reason)

**Rate Limiter:**

- `[:httpower, :rate_limit, :ok]` - Request allowed
- `[:httpower, :rate_limit, :wait]` - Waiting for tokens
- `[:httpower, :rate_limit, :exceeded]` - Rate limit exceeded

**Circuit Breaker:**

- `[:httpower, :circuit_breaker, :state_change]` - State transition (includes from_state, to_state, failure_count)
- `[:httpower, :circuit_breaker, :open]` - Request blocked by open circuit

**Deduplication:**

- `[:httpower, :dedup, :execute]` - First request executes
- `[:httpower, :dedup, :wait]` - Duplicate waits for in-flight request
- `[:httpower, :dedup, :cache_hit]` - Returns cached response

### Integration Examples

**Prometheus Metrics:**

```elixir
# Using telemetry_metrics_prometheus
distribution(
  "httpower.request.duration",
  event_name: [:httpower, :request, :stop],
  measurement: :duration,
  unit: {:native, :millisecond},
  tags: [:method, :status]
)
```

**OpenTelemetry:**

```elixir
# Using opentelemetry_telemetry
OpentelemetryTelemetry.register_application_tracer(:httpower)
```

**Custom Logging:**

```elixir
:telemetry.attach(
  "httpower-logger",
  [:httpower, :request, :stop],
  fn _event, measurements, metadata, _config ->
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
    Logger.info("HTTP #{metadata.method} #{metadata.url} - #{metadata.status} (#{duration_ms}ms)")
  end,
  nil
)
```

📖 **[Full Observability Guide](guides/observability.md)** - Complete event reference, measurements, metadata, and integration examples for Prometheus, OpenTelemetry, and Phoenix LiveDashboard.

## Development

```bash
# Install dependencies
mix deps.get

# Run tests
mix test

# Generate docs
mix docs

# Check coverage
mix test --cover
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for your changes
4. Ensure all tests pass with `mix test`
5. Submit a pull request

## License

MIT License

---

**HTTPower: Production reliability for your HTTP client.** ⚡

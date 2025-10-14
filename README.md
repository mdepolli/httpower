# HTTPower ⚡

HTTPower is a production-ready HTTP client library for Elixir that provides bulletproof HTTP behavior with advanced features like test mode blocking, smart retries, and comprehensive error handling.

[![Hex.pm](https://img.shields.io/hexpm/v/httpower)](https://hex.pm/packages/httpower)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue)](https://hexdocs.pm/httpower)

## Features

### 🛡️ **Production-Ready Reliability**

- **Circuit breaker**: Automatic failure detection and recovery with state tracking
- **Built-in rate limiting**: Token bucket algorithm with per-endpoint configuration
- **Request deduplication**: Prevent duplicate operations from double-clicks or race conditions
- **Comprehensive telemetry**: Deep observability with Elixir's `:telemetry` library
- **PCI-compliant logging**: Automatic sanitization of sensitive data in logs
- **Request/response correlation**: Trace requests with unique correlation IDs
- **Test mode blocking**: Prevents real HTTP requests during testing
- **Smart retry logic**: Intelligent retries with configurable policies
- **Clean error handling**: Never raises exceptions, always returns result tuples
- **SSL/Proxy support**: Full SSL verification and proxy configuration
- **Request timeout management**: Configurable timeouts with sensible defaults

### 🎯 **Perfect For**

- **API integrations** - Rate limiting and circuit breakers for third-party APIs
- **Payment processing** - PCI-compliant logging and audit trails
- **Microservices** - Reliability patterns across service boundaries
- **Financial services** - Compliance and observability requirements

## Table of Contents

- [Adapter Support](#adapter-support)
- [Quick Start](#quick-start)
  - [Installation](#installation)
  - [Basic Usage](#basic-usage)
- [Test Mode Integration](#test-mode-integration)
- [Configuration Options](#configuration-options)
- [PCI-Compliant Logging](#pci-compliant-logging)
- [Correlation IDs](#correlation-ids)
- [Rate Limiting](#rate-limiting)
- [Circuit Breaker](#circuit-breaker)
- [Request Deduplication](#request-deduplication)
- [Observability & Telemetry](#observability--telemetry)
- [Development](#development)
- [Documentation](#documentation)
- [License](#license)

## Adapter Support

HTTPower supports multiple HTTP clients through an adapter system:

- **Finch** (default) - High-performance HTTP client built on Mint with explicit connection pooling
- **Req** - Batteries-included HTTP client with automatic JSON handling
- **Tesla** - Flexible HTTP client with extensive middleware ecosystem

HTTPower's production features (circuit breaker, rate limiting, PCI logging, smart retries) work consistently across all adapters. For existing Tesla applications, your middleware continues to work unchanged - HTTPower adds reliability on top.

See [Migrating from Tesla](guides/migrating-from-tesla.md) or [Migrating from Req](guides/migrating-from-req.md) for adapter-specific guidance.

## Quick Start

### Installation

Add `httpower` and at least one HTTP client adapter to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:httpower, "~> 0.11.0"},

    # Choose at least one adapter:
    {:finch, "~> 0.20"},       # Recommended - high performance
    # OR
    {:req, "~> 0.4.0"},        # Batteries-included with auto-JSON
    # OR
    {:tesla, "~> 1.11"}        # If you already use Tesla
  ]
end
```

**Note:** HTTPower requires at least one adapter (Finch, Req, or Tesla). If multiple are present, Finch is used by default (can be overridden with the `adapter` option).

### Basic Usage

**Direct requests:**

```elixir
# Simple GET request
{:ok, response} = HTTPower.get("https://api.example.com/users")
IO.inspect(response.status)  # 200
IO.inspect(response.body)    # %{"users" => [...]}

# POST with data
{:ok, response} = HTTPower.post("https://api.example.com/users",
  body: "name=John&email=john@example.com",
  headers: %{"Content-Type" => "application/x-www-form-urlencoded"}
)
```

**Client-based usage (recommended for reusable configuration):**

```elixir
# Create a configured client
client = HTTPower.new(
  base_url: "https://api.example.com",
  headers: %{"authorization" => "Bearer #{token}"},
  timeout: 30,
  max_retries: 3
)

# Use the client for multiple requests
{:ok, users} = HTTPower.get(client, "/users")
{:ok, user} = HTTPower.get(client, "/users/123")
{:ok, created} = HTTPower.post(client, "/users", body: data)

# Error handling (never raises!)
case HTTPower.get("https://api.example.com") do
  {:ok, %HTTPower.Response{status: 200, body: body}} ->
    # Success case
    process_data(body)

  {:ok, %HTTPower.Response{status: 404}} ->
    # Handle 404 - still a successful HTTP response
    handle_not_found()

  {:error, %HTTPower.Error{reason: :timeout}} ->
    # Network timeout
    handle_timeout()

  {:error, %HTTPower.Error{reason: :econnrefused}} ->
    # Connection refused
    handle_connection_error()

  {:error, %HTTPower.Error{reason: :network_blocked}} ->
    # Blocked in test mode
    handle_test_mode()
end
```

## Test Mode Integration

HTTPower can completely block real HTTP requests during testing while allowing mocked requests:

```elixir
# In test_helper.exs
Application.put_env(:httpower, :test_mode, true)

# In your tests
defmodule MyAppTest do
  use ExUnit.Case

  test "API integration with mocking" do
    # Use HTTPower.Test for adapter-agnostic mocking
    HTTPower.Test.stub(fn conn ->
      Plug.Conn.resp(conn, 200, Jason.encode!(%{status: "success"}))
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

## Configuration Options

HTTPower supports extensive configuration at multiple levels. **Global configuration in `config.exs` is recommended** for production settings:

### Global Configuration (Recommended)

```elixir
# config/config.exs
config :httpower,
  # Retry configuration
  max_retries: 3,
  retry_safe: false,
  base_delay: 1000,
  max_delay: 30000,

  # Rate limiting (see Rate Limiting section)
  rate_limit: [
    enabled: true,
    requests: 100,
    per: :minute,
    strategy: :wait
  ],

  # Circuit breaker (see Circuit Breaker section)
  circuit_breaker: [
    enabled: true,
    failure_threshold: 5,
    timeout: 60_000
  ],

  # Logging (see PCI-Compliant Logging section)
  logging: [
    enabled: true,
    level: :info
  ]
```

**Priority:** Per-request options > Per-client options > Global configuration

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
  log_body: true,
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
2. Tokens are refilled at a fixed rate (e.g., 100 tokens per minute)
3. Each request consumes one token
4. If no tokens are available, the request either waits or returns an error

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

# Update rate limiter bucket from server headers
HTTPower.RateLimiter.update_from_headers("api.github.com", rate_limit_info)

# Get current bucket information
HTTPower.RateLimiter.get_info("api.github.com")
# => %{current_tokens: 42.0, last_refill_ms: 1234567890}
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
HTTPower.CircuitBreaker.open_circuit("payment_api")

# Manually close a circuit
HTTPower.CircuitBreaker.close_circuit("payment_api")

# Reset a circuit completely
HTTPower.CircuitBreaker.reset_circuit("payment_api")

# Check circuit state
HTTPower.CircuitBreaker.get_state("payment_api")
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
3. **Shares responses** - duplicate requests wait and receive the same response
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

## Roadmap

Planned features:

- **Phase 2**: Performance optimization, security features, middleware
- **Phase 3**: Advanced authentication, monitoring, streaming

Phase 1 (logging, rate limiting, circuit breaker patterns) is complete.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for your changes
4. Ensure all tests pass with `mix test`
5. Submit a pull request

## License

MIT License

---

**HTTPower: Because your HTTP requests deserve to be as powerful as they are reliable.** ⚡

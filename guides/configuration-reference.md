# Configuration Reference

Complete reference for all HTTPower configuration options.

## Configuration Levels

HTTPower supports three levels of configuration with clear precedence:

1. **Per-Request** (highest priority) - Options passed to individual requests
2. **Per-Client** (medium priority) - Options in `HTTPower.new()`
3. **Global** (lowest priority) - Options in `config.exs`

**Rule:** More specific configuration overrides less specific.

## Configuration Availability Matrix

This table shows which options are supported at each configuration level:

### Adapter Selection
| Option | Global Config | Per-Client | Per-Request | Notes |
|--------|---------------|------------|-------------|-------|
| `adapter` | ✅ | ✅ | ✅ | Global: `config :httpower, adapter:` |

### Testing
| Option | Global Config | Per-Client | Per-Request | Notes |
|--------|---------------|------------|-------------|-------|
| `test_mode` | ✅ | ❌ | ❌ | Global only |

### Retry Configuration
| Option | Global Config | Per-Client | Per-Request | Notes |
|--------|---------------|------------|-------------|-------|
| `max_retries` | ✅ | ✅ | ✅ | |
| `retry_safe` | ✅ | ✅ | ✅ | |
| `base_delay` | ✅ | ✅ | ✅ | |
| `max_delay` | ✅ | ✅ | ✅ | |
| `jitter_factor` | ✅ | ✅ | ✅ | |

### Rate Limiting
| Option | Global Config | Per-Client | Per-Request | Notes |
|--------|---------------|------------|-------------|-------|
| `rate_limit` | ✅ | ✅ | ✅ | Global: nested config |
| `rate_limit_key` | ❌ | ✅ | ✅ | Per-client/request only |

### Circuit Breaker
| Option | Global Config | Per-Client | Per-Request | Notes |
|--------|---------------|------------|-------------|-------|
| `circuit_breaker` | ✅ | ✅ | ✅ | Global: nested config |
| `circuit_breaker_key` | ❌ | ✅ | ✅ | Per-client/request only |

### Logging
| Option | Global Config | Per-Client | Per-Request | Notes |
|--------|---------------|------------|-------------|-------|
| `logging` | ✅ | ✅ | ✅ | Global: nested config |

### Request Options
| Option | Global Config | Per-Client | Per-Request | Notes |
|--------|---------------|------------|-------------|-------|
| `base_url` | ❌ | ✅ | ❌ | Per-client only |
| `headers` | ❌ | ✅ | ✅ | Merged across levels |
| `body` | ❌ | ❌ | ✅ | Per-request only (POST/PUT) |
| `timeout` | ❌ | ✅ | ✅ | Per-client/request only |
| `ssl_verify` | ❌ | ✅ | ✅ | Per-client/request only |
| `proxy` | ❌ | ✅ | ✅ | Per-client/request only |

## Global Configuration

Set in `config/config.exs`, `config/prod.exs`, etc.

```elixir
config :httpower,
  # Adapter (optional - auto-detects if not specified)
  adapter: HTTPower.Adapter.Req,  # or HTTPower.Adapter.Tesla

  # Retry Configuration
  max_retries: 3,
  retry_safe: false,
  base_delay: 1000,
  max_delay: 30000,
  jitter_factor: 0.2,

  # Rate Limiting
  rate_limit: [
    enabled: false,
    requests: 100,
    per: :minute,
    strategy: :wait,
    max_wait_time: 5000
  ],

  # Circuit Breaker
  circuit_breaker: [
    enabled: false,
    failure_threshold: 5,
    failure_threshold_percentage: nil,
    window_size: 10,
    timeout: 60_000,
    half_open_requests: 1
  ],

  # Logging
  logging: [
    enabled: true,
    level: :info,
    sanitize_headers: [],      # Additional headers to sanitize (adds to defaults)
    sanitize_body_fields: []   # Additional body fields to sanitize (adds to defaults)
  ],

  # Test Mode
  test_mode: false
```

## Adapter Configuration

### `adapter`
- **Type:** `module() | {module(), term()}`
- **Default:** Auto-detected (prefers Req, then Tesla)
- **Supported:** Global config, per-client, per-request
- **Description:** HTTP adapter to use. Can be specified globally or overridden per-client/request.

**Global Configuration (Simple):**
```elixir
# config/config.exs
config :httpower, adapter: HTTPower.Adapter.Req
# or
config :httpower, adapter: HTTPower.Adapter.Tesla
```

**Per-Client (Simple or with Pre-configured Client):**
```elixir
# Simple adapter module
client = HTTPower.new(
  adapter: HTTPower.Adapter.Req,
  base_url: "https://api.example.com"
)

# Adapter with pre-configured Tesla client
tesla_client = Tesla.client([
  Tesla.Middleware.BaseURL.new("https://api.example.com"),
  Tesla.Middleware.JSON
])

client = HTTPower.new(
  adapter: {HTTPower.Adapter.Tesla, tesla_client}
)
```

**Per-Request Override:**
```elixir
# Override the adapter for a specific request
HTTPower.get(url, adapter: HTTPower.Adapter.Tesla)
```

## Retry Configuration

### `max_retries`
- **Type:** `non_neg_integer()`
- **Default:** `3`
- **Description:** Maximum number of retry attempts for failed requests.
- **Example:**
  ```elixir
  config :httpower, max_retries: 5
  ```

### `retry_safe`
- **Type:** `boolean()`
- **Default:** `false`
- **Description:** Whether to retry on connection resets (`econnreset`). Only enable for idempotent operations.
- **Example:**
  ```elixir
  config :httpower, retry_safe: true
  ```

### `base_delay`
- **Type:** `non_neg_integer()` (milliseconds)
- **Default:** `1000`
- **Description:** Base delay for exponential backoff. Actual delay: `base_delay * 2^(attempt-1)`.
- **Example:**
  ```elixir
  config :httpower, base_delay: 2000  # Start with 2 second delay
  ```

### `max_delay`
- **Type:** `non_neg_integer()` (milliseconds)
- **Default:** `30000`
- **Description:** Maximum delay cap for exponential backoff.
- **Example:**
  ```elixir
  config :httpower, max_delay: 60000  # Cap at 60 seconds
  ```

### `jitter_factor`
- **Type:** `float()` (0.0 to 1.0)
- **Default:** `0.2`
- **Description:** Randomization factor to prevent thundering herd. Delay multiplied by `(1 - jitter_factor * random())`.
- **Example:**
  ```elixir
  config :httpower, jitter_factor: 0.3  # 30% jitter
  ```

### Retryable Conditions

HTTPower retries on:
- **Status codes:** 408, 429, 500, 502, 503, 504
- **Errors:** `:timeout`, `:closed`, `:econnrefused`, `:econnreset` (if `retry_safe: true`)

## Rate Limiting Configuration

### `rate_limit.enabled`
- **Type:** `boolean()`
- **Default:** `false`
- **Description:** Enable/disable rate limiting globally.
- **Example:**
  ```elixir
  config :httpower, rate_limit: [enabled: true]
  ```

### `rate_limit.requests`
- **Type:** `pos_integer()`
- **Default:** `100`
- **Description:** Maximum number of requests allowed per time window.
- **Example:**
  ```elixir
  config :httpower, rate_limit: [requests: 60]
  ```

### `rate_limit.per`
- **Type:** `:second | :minute | :hour`
- **Default:** `:minute`
- **Description:** Time window for rate limiting.
- **Example:**
  ```elixir
  config :httpower, rate_limit: [per: :second]
  ```

### `rate_limit.strategy`
- **Type:** `:wait | :error`
- **Default:** `:wait`
- **Description:** How to handle rate limit exceeded:
  - `:wait` - Block until tokens available (up to `max_wait_time`)
  - `:error` - Return `{:error, :too_many_requests}` immediately
- **Example:**
  ```elixir
  config :httpower, rate_limit: [strategy: :error]
  ```

### `rate_limit.max_wait_time`
- **Type:** `non_neg_integer()` (milliseconds)
- **Default:** `5000`
- **Description:** Maximum time to wait for rate limit tokens when using `:wait` strategy.
- **Example:**
  ```elixir
  config :httpower, rate_limit: [max_wait_time: 10000]
  ```

### Per-Request Rate Limiting

```elixir
HTTPower.get(url,
  rate_limit: [requests: 10, per: :second],
  rate_limit_key: "special_endpoint"  # Custom bucket key
)
```

## Circuit Breaker Configuration

### `circuit_breaker.enabled`
- **Type:** `boolean()`
- **Default:** `false`
- **Description:** Enable/disable circuit breaker globally.
- **Example:**
  ```elixir
  config :httpower, circuit_breaker: [enabled: true]
  ```

### `circuit_breaker.failure_threshold`
- **Type:** `pos_integer()`
- **Default:** `5`
- **Description:** Number of failures in sliding window before opening circuit.
- **Example:**
  ```elixir
  config :httpower, circuit_breaker: [failure_threshold: 3]
  ```

### `circuit_breaker.failure_threshold_percentage`
- **Type:** `float()` (0.0 to 100.0) or `nil`
- **Default:** `nil`
- **Description:** Alternative to absolute threshold. Opens circuit when failure rate exceeds percentage. Requires `window_size` requests minimum.
- **Example:**
  ```elixir
  config :httpower, circuit_breaker: [
    failure_threshold_percentage: 50.0,  # Open at 50% failure rate
    window_size: 20
  ]
  ```

### `circuit_breaker.window_size`
- **Type:** `pos_integer()`
- **Default:** `10`
- **Description:** Number of recent requests to track in sliding window.
- **Example:**
  ```elixir
  config :httpower, circuit_breaker: [window_size: 20]
  ```

### `circuit_breaker.timeout`
- **Type:** `pos_integer()` (milliseconds)
- **Default:** `60000`
- **Description:** How long circuit stays open before transitioning to half-open.
- **Example:**
  ```elixir
  config :httpower, circuit_breaker: [timeout: 30_000]  # 30 seconds
  ```

### `circuit_breaker.half_open_requests`
- **Type:** `pos_integer()`
- **Default:** `1`
- **Description:** Number of test requests allowed in half-open state. All must succeed to close circuit.
- **Example:**
  ```elixir
  config :httpower, circuit_breaker: [half_open_requests: 3]
  ```

### Per-Request Circuit Breaker

```elixir
HTTPower.get(url,
  circuit_breaker: [failure_threshold: 3, timeout: 30_000],
  circuit_breaker_key: "payment_api"  # Custom circuit key
)
```

### Manual Circuit Control

```elixir
# Check state
HTTPower.CircuitBreaker.get_state("my_api")  # => :closed | :open | :half_open | nil

# Manually open
HTTPower.CircuitBreaker.open_circuit("my_api")

# Manually close
HTTPower.CircuitBreaker.close_circuit("my_api")

# Reset completely
HTTPower.CircuitBreaker.reset_circuit("my_api")
```

## Logging Configuration

### `logging.enabled`
- **Type:** `boolean()`
- **Default:** `true`
- **Description:** Enable/disable HTTP request/response logging.
- **Example:**
  ```elixir
  config :httpower, logging: [enabled: false]
  ```

### `logging.level`
- **Type:** `:debug | :info | :warning | :error`
- **Default:** `:info`
- **Description:** Log level for HTTP requests.
- **Example:**
  ```elixir
  config :httpower, logging: [level: :debug]
  ```

### `logging.sanitize_headers`
- **Type:** `list(String.t())`
- **Default:** `["authorization", "api-key", "x-api-key"]`
- **Description:** Additional header names to sanitize (case-insensitive). **Additive** - adds to defaults, does not replace them.
- **Example:**
  ```elixir
  config :httpower, logging: [
    sanitize_headers: ["x-custom-token", "x-secret"]
  ]
  # Final sanitized headers: authorization, api-key, x-api-key, x-custom-token, x-secret
  ```

### `logging.sanitize_body_fields`
- **Type:** `list(String.t())`
- **Default:** `["password", "credit_card", "cvv", "card_number"]`
- **Description:** Additional body field names to sanitize in JSON/form data. **Additive** - adds to defaults, does not replace them.
- **Example:**
  ```elixir
  config :httpower, logging: [
    sanitize_body_fields: ["ssn", "tax_id", "secret"]
  ]
  # Final sanitized fields: password, credit_card, cvv, card_number, ssn, tax_id, secret
  ```

### Per-Request Logging Control

```elixir
# Disable logging for specific request
HTTPower.get(url, logging: false)

# Additional sanitization for specific request
HTTPower.post(url,
  logging: [
    sanitize_body_fields: ["custom_field"]  # Adds to global + default sanitization
  ]
)
```

## Request Options

### `timeout`
- **Type:** `pos_integer()` (seconds)
- **Default:** `60`
- **Description:** Request timeout in seconds.
- **Example:**
  ```elixir
  HTTPower.get(url, timeout: 30)
  ```

### `headers`
- **Type:** `map()`
- **Default:** `%{}`
- **Description:** HTTP headers for the request.
- **Example:**
  ```elixir
  HTTPower.get(url, headers: %{"authorization" => "Bearer token"})
  ```

### `body`
- **Type:** `String.t() | binary()`
- **Default:** `""`
- **Description:** Request body for POST/PUT requests.
- **Example:**
  ```elixir
  HTTPower.post(url, body: Jason.encode!(%{name: "John"}))
  ```

### `ssl_verify`
- **Type:** `boolean()`
- **Default:** `true`
- **Description:** Enable SSL certificate verification.
- **Example:**
  ```elixir
  HTTPower.get(url, ssl_verify: false)  # Not recommended for production
  ```

### `proxy`
- **Type:** `:system | keyword()`
- **Default:** `:system`
- **Description:** Proxy configuration. `:system` uses system environment variables.
- **Example:**
  ```elixir
  HTTPower.get(url, proxy: [host: "proxy.example.com", port: 8080])
  ```

## Per-Client Configuration

Create reusable clients with `HTTPower.new()`:

```elixir
client = HTTPower.new(
  base_url: "https://api.example.com",
  headers: %{"authorization" => "Bearer #{token}"},
  timeout: 30,
  max_retries: 5,
  circuit_breaker: [failure_threshold: 3],
  rate_limit: [requests: 100, per: :minute]
)

# Use the client
HTTPower.get(client, "/users")
HTTPower.post(client, "/users", body: data)
```

## Test Mode

### `test_mode`
- **Type:** `boolean()`
- **Default:** `false`
- **Description:** When enabled, blocks all real HTTP requests unless they include a `:plug` option.
- **Example:**
  ```elixir
  # In test_helper.exs
  Application.put_env(:httpower, :test_mode, true)

  # In tests
  Req.Test.stub(HTTPower, fn conn ->
    Req.Test.json(conn, %{"status" => "ok"})
  end)

  HTTPower.get(url, plug: {Req.Test, HTTPower})  # Allowed
  HTTPower.get(url)  # Blocked with {:error, :network_blocked}
  ```

## Configuration Priority Examples

### Example 1: Override global with per-client

```elixir
# Global config
config :httpower, max_retries: 3

# Per-client override
client = HTTPower.new(max_retries: 5)  # Uses 5, not 3
```

### Example 2: Override per-client with per-request

```elixir
client = HTTPower.new(timeout: 30)

# This request uses 60 second timeout
HTTPower.get(client, "/slow", timeout: 60)

# This request uses client's 30 second timeout
HTTPower.get(client, "/fast")
```

### Example 3: Header merging

```elixir
# Global config
config :httpower, headers: %{"user-agent" => "HTTPower/1.0"}

# Per-client config
client = HTTPower.new(headers: %{"authorization" => "Bearer token"})

# Per-request config
HTTPower.get(client, "/api",
  headers: %{"x-request-id" => "123"}
)

# Final headers include all three:
# {
#   "user-agent" => "HTTPower/1.0",
#   "authorization" => "Bearer token",
#   "x-request-id" => "123"
# }
```

## Environment-Specific Configuration

### Development

```elixir
# config/dev.exs
config :httpower,
  logging: [enabled: true, level: :debug],
  circuit_breaker: [enabled: false],  # Disabled for easier debugging
  rate_limit: [enabled: false]
```

### Test

```elixir
# config/test.exs
config :httpower,
  test_mode: true,
  logging: [enabled: false],
  circuit_breaker: [enabled: false],
  rate_limit: [enabled: false]
```

### Production

```elixir
# config/prod.exs
config :httpower,
  max_retries: 3,
  circuit_breaker: [
    enabled: true,
    failure_threshold: 5,
    timeout: 60_000
  ],
  rate_limit: [
    enabled: true,
    requests: 100,
    per: :minute,
    strategy: :wait
  ],
  logging: [
    enabled: true,
    level: :info,
    sanitize_headers: ["authorization", "api-key"],
    sanitize_body_fields: ["password", "credit_card", "cvv"]
  ]
```

## Next Steps

- Read [Production Deployment Guide](production-deployment.md) for production setup
- See [Migrating from Tesla](migrating-from-tesla.md) or [Migrating from Req](migrating-from-req.md)
- Check `guides/examples/` for runnable examples

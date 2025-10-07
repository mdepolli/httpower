# Observability with Telemetry

HTTPower emits comprehensive telemetry events using Elixir's built-in `:telemetry` library, enabling deep observability into HTTP requests, retries, rate limiting, circuit breakers, and request deduplication.

## Table of Contents

- [Quick Start](#quick-start)
- [Event Reference](#event-reference)
  - [HTTP Request Lifecycle](#http-request-lifecycle)
  - [Retry Events](#retry-events)
  - [Rate Limiter Events](#rate-limiter-events)
  - [Circuit Breaker Events](#circuit-breaker-events)
  - [Deduplication Events](#deduplication-events)
- [Integration Examples](#integration-examples)
  - [Basic Logging](#basic-logging)
  - [Prometheus Metrics](#prometheus-metrics)
  - [OpenTelemetry](#opentelemetry)
  - [Phoenix LiveDashboard](#phoenix-livedashboard)
- [Best Practices](#best-practices)

## Quick Start

Attach a telemetry handler to capture HTTPower events:

```elixir
:telemetry.attach_many(
  "httpower-handler",
  [
    [:httpower, :request, :start],
    [:httpower, :request, :stop],
    [:httpower, :retry, :attempt]
  ],
  fn event, measurements, metadata, _config ->
    # Handle event
    IO.inspect({event, measurements, metadata})
  end,
  nil
)
```

## Event Reference

### HTTP Request Lifecycle

HTTPower uses `:telemetry.span/3` to emit start, stop, and exception events for every HTTP request.

#### `[:httpower, :request, :start]`

Emitted when an HTTP request begins.

**Measurements:**
- `system_time` - System time when request started (integer)

**Metadata:**
- `method` - HTTP method (`:get`, `:post`, `:put`, `:delete`)
- `url` - Sanitized URL (query params and fragments stripped for lower cardinality)

**Example:**
```elixir
event: [:httpower, :request, :start]
measurements: %{system_time: 1640995200000000000}
metadata: %{method: :get, url: "https://api.example.com/users"}
```

#### `[:httpower, :request, :stop]`

Emitted when an HTTP request completes (success or error).

**Measurements:**
- `duration` - Request duration in native time units (use `System.convert_time_unit/3`)
- `monotonic_time` - Monotonic time when request completed

**Metadata:**
- `method` - HTTP method
- `url` - Sanitized URL
- `status` - HTTP status code (for successful responses)
- `error_type` - Error reason atom (for failed requests)
- `retry_count` - Number of retries performed (default: 0)

**Example (success):**
```elixir
event: [:httpower, :request, :stop]
measurements: %{duration: 45_000_000, monotonic_time: -576460751234567890}
metadata: %{
  method: :get,
  url: "https://api.example.com/users",
  status: 200,
  retry_count: 0
}
```

**Example (error):**
```elixir
event: [:httpower, :request, :stop]
measurements: %{duration: 5_000_000, monotonic_time: -576460751234567890}
metadata: %{
  method: :post,
  url: "https://api.example.com/orders",
  error_type: :timeout,
  retry_count: 3
}
```

#### `[:httpower, :request, :exception]`

Emitted when an unhandled exception occurs during request processing. This is rare since HTTPower catches exceptions and converts them to `{:error, reason}` tuples.

**Measurements:**
- `duration` - Request duration in native time units

**Metadata:**
- `method` - HTTP method
- `url` - Sanitized URL
- `kind` - Exception kind (`:throw`, `:error`, `:exit`)
- `reason` - Exception reason
- `stacktrace` - Exception stacktrace

### Retry Events

#### `[:httpower, :retry, :attempt]`

Emitted before each retry attempt.

**Measurements:**
- `attempt_number` - Current attempt number (2 for first retry, 3 for second, etc.)
- `delay_ms` - Delay before this retry in milliseconds

**Metadata:**
- `method` - HTTP method
- `url` - Sanitized URL
- `reason` - Reason for retry (`:timeout`, `{:http_status, 500}`, etc.)

**Example:**
```elixir
event: [:httpower, :retry, :attempt]
measurements: %{attempt_number: 2, delay_ms: 1000}
metadata: %{
  method: :get,
  url: "https://api.example.com/users",
  reason: {:http_status, 503}
}
```

### Rate Limiter Events

#### `[:httpower, :rate_limit, :ok]`

Emitted when a request passes rate limiting checks.

**Measurements:**
- `tokens_remaining` - Tokens remaining in bucket (float)
- `wait_time_ms` - Wait time (always 0 for ok event)

**Metadata:**
- `bucket_key` - Rate limit bucket identifier

**Example:**
```elixir
event: [:httpower, :rate_limit, :ok]
measurements: %{tokens_remaining: 45.5, wait_time_ms: 0}
metadata: %{bucket_key: "api.example.com"}
```

#### `[:httpower, :rate_limit, :wait]`

Emitted when rate limit is exceeded and the `:wait` strategy is used.

**Measurements:**
- `wait_time_ms` - Time spent waiting for tokens (integer)

**Metadata:**
- `bucket_key` - Rate limit bucket identifier
- `strategy` - Rate limit strategy (`:wait`)

**Example:**
```elixir
event: [:httpower, :rate_limit, :wait]
measurements: %{wait_time_ms: 250}
metadata: %{bucket_key: "api.example.com", strategy: :wait}
```

#### `[:httpower, :rate_limit, :exceeded]`

Emitted when rate limit is exceeded and the `:error` strategy is used.

**Measurements:**
- `tokens_remaining` - Tokens remaining (always 0)

**Metadata:**
- `bucket_key` - Rate limit bucket identifier
- `strategy` - Rate limit strategy (`:error`)

**Example:**
```elixir
event: [:httpower, :rate_limit, :exceeded]
measurements: %{tokens_remaining: 0}
metadata: %{bucket_key: "api.example.com", strategy: :error}
```

### Circuit Breaker Events

#### `[:httpower, :circuit_breaker, :state_change]`

Emitted when circuit breaker transitions between states.

**Measurements:**
- `timestamp` - System timestamp of transition

**Metadata:**
- `circuit_key` - Circuit breaker identifier
- `from_state` - Previous state (`:closed`, `:open`, `:half_open`)
- `to_state` - New state
- `failure_count` - Number of failures in window
- `failure_rate` - Failure rate as decimal (e.g., 0.6 = 60%)

**Example:**
```elixir
event: [:httpower, :circuit_breaker, :state_change]
measurements: %{timestamp: 1640995200000000000}
metadata: %{
  circuit_key: "payment.api.example.com",
  from_state: :closed,
  to_state: :open,
  failure_count: 5,
  failure_rate: 0.83
}
```

#### `[:httpower, :circuit_breaker, :open]`

Emitted when a request is blocked by an open circuit.

**Measurements:** (empty map)

**Metadata:**
- `circuit_key` - Circuit breaker identifier

**Example:**
```elixir
event: [:httpower, :circuit_breaker, :open]
measurements: %{}
metadata: %{circuit_key: "payment.api.example.com"}
```

### Deduplication Events

#### `[:httpower, :dedup, :execute]`

Emitted when a request is the first occurrence and will be executed.

**Measurements:** (empty map)

**Metadata:**
- `dedup_key` - Deduplication hash identifying the request

**Example:**
```elixir
event: [:httpower, :dedup, :execute]
measurements: %{}
metadata: %{dedup_key: "2cdff299ad44f172e45a54feaafdac27f230a63471469182a64049689e6bf24b"}
```

#### `[:httpower, :dedup, :wait]`

Emitted when a duplicate request waits for an in-flight request to complete.

**Measurements:**
- `wait_time_ms` - Time spent waiting in milliseconds

**Metadata:**
- `dedup_key` - Deduplication hash

**Example:**
```elixir
event: [:httpower, :dedup, :wait]
measurements: %{wait_time_ms: 450}
metadata: %{dedup_key: "2cdff299ad44f172e45a54feaafdac27f230a63471469182a64049689e6bf24b"}
```

#### `[:httpower, :dedup, :cache_hit]`

Emitted when a request returns a cached response (within TTL).

**Measurements:** (empty map)

**Metadata:**
- `dedup_key` - Deduplication hash

**Example:**
```elixir
event: [:httpower, :dedup, :cache_hit]
measurements: %{}
metadata: %{dedup_key: "2cdff299ad44f172e45a54feaafdac27f230a63471469182a64049689e6bf24b"}
```

## Integration Examples

### Basic Logging

**Built-in PCI-Compliant Logger (Recommended)**

HTTPower includes a built-in logger with automatic PCI-compliant data sanitization:

```elixir
# In your application.ex
def start(_type, _args) do
  # Attach the built-in logger
  HTTPower.Logger.attach(
    level: :info,
    log_headers: true,
    log_body: true
  )

  # ... rest of your supervision tree
end
```

The built-in logger automatically sanitizes sensitive data (credit cards, passwords, API keys, etc.) and includes correlation IDs for request tracing.

**Custom Logger**

Or create your own custom telemetry handler for logging:

```elixir
defmodule MyApp.HTTPowerLogger do
  require Logger

  def setup do
    :telemetry.attach_many(
      "httpower-logger",
      [
        [:httpower, :request, :stop]
      ],
      &handle_event/4,
      nil
    )
  end

  def handle_event([:httpower, :request, :stop], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    status = Map.get(metadata, :status, "error")
    method = metadata.method |> to_string() |> String.upcase()

    Logger.info("HTTP #{method} #{metadata.url} - #{status} (#{duration_ms}ms)")
  end
end

# In your application.ex
MyApp.HTTPowerLogger.setup()
```

### Prometheus Metrics

Export HTTPower metrics to Prometheus using `telemetry_metrics` and `telemetry_metrics_prometheus`:

```elixir
# mix.exs
defp deps do
  [
    {:httpower, "~> 0.9"},
    {:telemetry_metrics, "~> 1.0"},
    {:telemetry_metrics_prometheus, "~> 1.1"}
  ]
end

# lib/my_app/telemetry.ex
defmodule MyApp.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus, [metrics: metrics()]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp metrics do
    [
      # HTTP Request duration
      distribution(
        "httpower.request.duration",
        event_name: [:httpower, :request, :stop],
        measurement: :duration,
        unit: {:native, :millisecond},
        tags: [:method, :status],
        tag_values: fn metadata ->
          %{
            method: metadata.method,
            status: Map.get(metadata, :status, "error")
          }
        end
      ),

      # HTTP Request count
      counter(
        "httpower.request.count",
        event_name: [:httpower, :request, :stop],
        tags: [:method, :status]
      ),

      # Retry attempts
      counter(
        "httpower.retry.attempts",
        event_name: [:httpower, :retry, :attempt],
        tags: [:method, :reason],
        tag_values: fn metadata ->
          %{
            method: metadata.method,
            reason: extract_reason(metadata.reason)
          }
        end
      ),

      # Circuit breaker state changes
      counter(
        "httpower.circuit_breaker.state_changes",
        event_name: [:httpower, :circuit_breaker, :state_change],
        tags: [:from_state, :to_state]
      ),

      # Rate limit events
      counter(
        "httpower.rate_limit.events",
        event_name: [:httpower, :rate_limit, :ok],
        tags: [:bucket_key]
      ),

      # Rate limit exceeded
      counter(
        "httpower.rate_limit.exceeded",
        event_name: [:httpower, :rate_limit, :exceeded],
        tags: [:bucket_key]
      )
    ]
  end

  defp extract_reason({:http_status, status}), do: "http_#{status}"
  defp extract_reason(reason) when is_atom(reason), do: to_string(reason)
  defp extract_reason(_), do: "unknown"
end
```

### OpenTelemetry

Integrate with OpenTelemetry using `opentelemetry_telemetry`:

```elixir
# mix.exs
defp deps do
  [
    {:httpower, "~> 0.9"},
    {:opentelemetry, "~> 1.0"},
    {:opentelemetry_telemetry, "~> 1.0"}
  ]
end

# lib/my_app/application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    # Attach OpenTelemetry handler to HTTPower events
    OpentelemetryTelemetry.register_application_tracer(:httpower)

    children = [
      # ... your app children
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

The HTTPower telemetry events will automatically create OpenTelemetry spans with proper attributes:

- HTTP requests become spans with method, url, status
- Retries add span events
- Circuit breaker state changes add span events
- Rate limiting adds span attributes

### Phoenix LiveDashboard

Display HTTPower metrics in Phoenix LiveDashboard:

```elixir
# mix.exs
defp deps do
  [
    {:httpower, "~> 0.9"},
    {:phoenix_live_dashboard, "~> 0.8"}
  ]
end

# lib/my_app_web/telemetry.ex
defmodule MyAppWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # HTTP metrics
      summary("httpower.request.duration",
        unit: {:native, :millisecond},
        tags: [:method]
      ),
      counter("httpower.request.count", tags: [:method, :status]),

      # Reliability metrics
      counter("httpower.retry.attempts", tags: [:method]),
      counter("httpower.circuit_breaker.state_changes", tags: [:to_state]),
      counter("httpower.rate_limit.exceeded", tags: [:bucket_key])
    ]
  end

  defp periodic_measurements do
    []
  end
end

# lib/my_app_web/router.ex
live_dashboard "/dashboard",
  metrics: MyAppWeb.Telemetry
```

## Best Practices

### 1. URL Sanitization

HTTPower automatically sanitizes URLs in telemetry events by removing query parameters and fragments. This prevents high cardinality in metrics systems:

```elixir
# Original URL
"https://api.example.com/users?token=abc123&page=5#section"

# Sanitized in telemetry
"https://api.example.com/users"
```

Default ports (80 for HTTP, 443 for HTTPS) are also stripped.

### 2. Cardinality Management

When creating metrics, be mindful of tag cardinality:

**Good (low cardinality):**
```elixir
tags: [:method, :status]  # Limited values
```

**Bad (high cardinality):**
```elixir
tags: [:url]  # Could have thousands of unique values
```

### 3. Duration Conversion

Always convert duration measurements from native time units:

```elixir
duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)
```

### 4. Error Handling in Handlers

Telemetry handlers should never crash:

```elixir
def handle_event(event, measurements, metadata, _config) do
  # Your logic here
rescue
  exception ->
    Logger.error("Telemetry handler error: #{inspect(exception)}")
    :ok
end
```

### 5. Detaching Handlers

Always detach handlers in tests:

```elixir
setup do
  ref = make_ref()

  :telemetry.attach_many(
    ref,
    events,
    &handle_event/4,
    nil
  )

  on_exit(fn -> :telemetry.detach(ref) end)

  :ok
end
```

### 6. Selective Sampling

For high-traffic applications, consider sampling:

```elixir
def handle_event(event, measurements, metadata, _config) do
  if :rand.uniform() < 0.1 do  # Sample 10%
    # Process event
  end
end
```

### 7. Correlation IDs

HTTPower's logging includes correlation IDs. Consider adding them to telemetry for request tracing:

```elixir
# In metadata enrichment
defp enrich_metadata(metadata) do
  Map.put(metadata, :correlation_id, Logger.metadata()[:request_id])
end
```

## Further Reading

- [Telemetry Documentation](https://hexdocs.pm/telemetry/)
- [Telemetry Metrics](https://hexdocs.pm/telemetry_metrics/)
- [OpenTelemetry Erlang](https://opentelemetry.io/docs/languages/erlang/)
- [Phoenix Telemetry](https://hexdocs.pm/phoenix/telemetry.html)

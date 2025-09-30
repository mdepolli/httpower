# HTTPower ⚡

HTTPower is a production-ready HTTP client library for Elixir that provides bulletproof HTTP behavior with advanced features like test mode blocking, smart retries, and comprehensive error handling.

[![CI](https://img.shields.io/github/workflow/status/mdepolli/httpower/CI)](https://github.com/mdepolli/httpower/actions)
[![Coverage](https://img.shields.io/badge/coverage-62.65%25-yellow)](https://github.com/mdepolli/httpower)
[![Hex.pm](https://img.shields.io/hexpm/v/httpower)](https://hex.pm/packages/httpower)
[![Documentation](https://img.shields.io/badge/docs-hexdocs-blue)](https://hexdocs.pm/httpower)

## Features

### 🛡️ **Production-Ready Reliability**

- **Test mode blocking**: Prevents real HTTP requests during testing
- **Smart retry logic**: Intelligent retries with configurable policies
- **Clean error handling**: Never raises exceptions, always returns result tuples
- **SSL/Proxy support**: Full SSL verification and proxy configuration
- **Request timeout management**: Configurable timeouts with sensible defaults

### 🔧 **Developer-Friendly**

- **Req.Test integration**: Seamless mocking for tests
- **Comprehensive error messages**: Human-readable error descriptions
- **Zero-config defaults**: Works great out of the box
- **Elixir-idiomatic**: Proper pattern matching and result tuples

### 🚀 **Coming Soon** (Phase 1)

- **HTTP request/response logging**: PCI-compliant debugging with data sanitization
- **Rate limiting**: Built-in token bucket algorithm with per-endpoint configuration
- **Circuit breaker**: Automatic failure detection and recovery
- **Performance metrics**: Request timing and tracing with correlation IDs

## Adapter Support

HTTPower works with multiple HTTP clients through its adapter system, allowing you to choose the right foundation for your needs:

### **Req Adapter** (Default - Batteries Included)
Perfect for new projects and simple use cases. Req provides automatic JSON handling, compression, and a friendly API.

```elixir
# Works out of the box - no configuration needed
HTTPower.get("https://api.example.com/users")
```

### **Tesla Adapter** (Bring Your Own Configuration)
Ideal for existing applications or when you need specific HTTP client features. Use your existing Tesla setup and add HTTPower's production features on top.

```elixir
# Use your existing Tesla client
tesla_client = MyApp.ApiClient.client()

client = HTTPower.new(
  adapter: {HTTPower.Adapter.Tesla, tesla_client}
)

HTTPower.get(client, "/users")
```

**Why adapters?** HTTPower's production features (retry logic, circuit breakers, rate limiting, PCI logging) work consistently across all adapters. Choose the HTTP client that fits your architecture, get the reliability patterns you need.

## Quick Start

### Installation

Add `httpower` and at least one HTTP client adapter to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:httpower, "~> 0.3.0"},

    # Choose at least one adapter:
    {:req, "~> 0.4.0"},        # Recommended for new projects
    # OR
    {:tesla, "~> 1.11"}        # If you already use Tesla
  ]
end
```

**Note:** HTTPower requires either Req or Tesla. If both are present, Req is used by default (can be overridden with the `adapter` option).

### Basic Usage

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

# With configuration options
{:ok, response} = HTTPower.get("https://api.example.com/slow-endpoint",
  timeout: 30,           # 30 second timeout
  max_retries: 5,        # Retry up to 5 times
  retry_safe: true       # Retry connection resets
)

# Error handling (never raises!)
case HTTPower.get("https://unreachable-api.com") do
  {:ok, response} ->
    IO.puts("Success: #{response.status}")
  {:error, error} ->
    IO.puts("Failed: #{error.message}")  # "Connection refused"
end
```

## Test Mode Integration

HTTPower can completely block real HTTP requests during testing while allowing mocked requests:

```elixir
# In test_helper.exs or test configuration
Application.put_env(:httpower, :test_mode, true)

# In your tests
defmodule MyAppTest do
  use ExUnit.Case

  test "API integration with mocking" do
    # This will work - uses Req.Test
    Req.Test.stub(HTTPower, fn conn ->
      Req.Test.json(conn, %{status: "success"})
    end)

    {:ok, response} = HTTPower.get("https://api.example.com/test",
      plug: {Req.Test, HTTPower}
    )
    assert response.body == %{"status" => "success"}
  end

  test "real requests are blocked" do
    # This will be blocked in test mode
    {:error, error} = HTTPower.get("https://real-api.com")
    assert error.reason == :network_blocked
  end
end
```

## Configuration Options

HTTPower supports extensive configuration for production use:

```elixir
HTTPower.get("https://api.example.com/endpoint",
  # Request configuration
  timeout: 60,                    # Request timeout in seconds (default: 60)
  max_retries: 3,                 # Maximum retry attempts (default: 3)
  retry_safe: false,              # Retry connection resets (default: false)

  # Headers and body
  headers: %{
    "Authorization" => "Bearer token",
    "User-Agent" => "MyApp/1.0"
  },
  body: "request data",

  # SSL and proxy
  ssl_verify: true,               # Enable SSL verification (default: true)
  proxy: :system,                 # Use system proxy settings
  # proxy: [host: "proxy.com", port: 8080],  # Custom proxy

  # Additional Req options are passed through
  connect_timeout: 15_000
)
```

## Error Handling

HTTPower provides comprehensive error handling with clean result tuples:

```elixir
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

## Production Considerations

HTTPower is designed for production use with:

### Reliability

- **Never raises exceptions** - All errors returned as `{:error, reason}` tuples
- **Automatic retries** for transient failures (timeouts, connection issues)
- **Request timeout management** to prevent hanging requests
- **SSL verification** enabled by default for security

### Testing

- **Complete test mode blocking** prevents accidental external calls in tests
- **Req.Test integration** for easy mocking and stubbing
- **Deterministic behavior** for reliable CI/CD pipelines

### Observability (Coming Soon)

- **Request/response logging** with PCI-compliant data sanitization
- **Performance metrics** with request timing and correlation IDs
- **Circuit breaker patterns** for failing services

## Why HTTPower?

HTTPower adds production reliability patterns on top of your HTTP client choice:

### **vs Building It Yourself**
Get circuit breakers, rate limiting, PCI-compliant logging, and telemetry integration without building and maintaining them.

### **vs Using Raw HTTP Clients**
- **Req/Tesla/HTTPoison**: Great HTTP clients, but lack production patterns like circuit breakers, rate limiting, and compliance features
- **HTTPower**: Use your preferred HTTP client (Req or Tesla) + get enterprise reliability features

### **Adapter Flexibility**
- **New projects**: Use Req adapter for simplicity
- **Existing apps**: Use Tesla adapter, keep your configuration
- **Consistent features**: Circuit breakers, rate limiting, retry logic work the same regardless of adapter

Perfect for:

- **Payment processing** - PCI-compliant logging and audit trails
- **API integrations** - Rate limiting and circuit breakers for third-party APIs
- **Microservices** - Reliability patterns across service boundaries
- **Financial services** - Compliance and observability requirements

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

See [ROADMAP.md](ROADMAP.md) for planned features including:

- **Phase 1**: Logging, rate limiting, circuit breaker patterns
- **Phase 2**: Performance optimization, security features, middleware
- **Phase 3**: Advanced authentication, monitoring, streaming

## Contributing

1. Fork the repository
2. Create a feature branch
3. Add tests for your changes
4. Ensure all tests pass with `mix test`
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) for details.

---

**HTTPower: Because your HTTP requests deserve to be as powerful as they are reliable.** ⚡

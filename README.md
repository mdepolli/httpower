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

## Quick Start

### Installation

Add `httpower` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:httpower, "~> 0.1.0"}
  ]
end
```

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

HTTPower fills the gap between simple HTTP clients and complex production needs:

- **vs HTTPoison**: Better error handling, test mode blocking, modern Elixir patterns
- **vs Req**: Adds production features like retry logic, test blocking, advanced configuration
- **vs Tesla**: Simpler API, better defaults, built-in reliability patterns

Perfect for:

- **Payment processing** (PCI-compliant features)
- **API integrations** (reliable with smart retries)
- **Microservices** (test mode blocking, comprehensive error handling)
- **Production applications** (timeout management, SSL verification)

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

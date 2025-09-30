# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2025-09-30

### Added

- **Built-in rate limiting** with token bucket algorithm
- `HTTPower.RateLimiter` GenServer for managing rate limit state
- `HTTPower.Application` supervision tree for fault tolerance
- **Two rate limiting strategies**:
  - `:wait` - Blocks until tokens are available (up to `max_wait_time`)
  - `:error` - Returns `{:error, :rate_limit_exceeded}` immediately
- **Flexible rate limit configuration**:
  - Global configuration via `config :httpower, :rate_limit`
  - Per-client configuration via `HTTPower.new/1`
  - Per-request configuration via request options
  - Custom bucket keys for grouping requests
- **ETS-based storage** for high performance and low latency
- **Automatic bucket cleanup** removes inactive buckets after 5 minutes
- **Time window support**: `:second`, `:minute`, `:hour`
- Thread-safe rate limiting with atomic ETS operations
- Comprehensive test suite (23 new tests covering token bucket algorithm, strategies, concurrent access)

### Changed

- Updated `HTTPower.Client` to check rate limits before each request
- Rate limiting integrated into request flow (happens before logging)
- Default bucket key uses URL host (can be overridden with `:rate_limit_key`)

### Fixed

- Fixed Plug.Conn undefined warnings by adding `@compile {:no_warn_undefined}` directive to `HTTPower.Test`

### Technical Details

- Token bucket algorithm: tokens refill continuously at configured rate
- Refill rate calculated as: `max_tokens / time_window_ms`
- Elapsed time since last refill determines available tokens
- GenServer handles concurrent access with ETS atomic operations
- Cleanup runs every 60 seconds, removes buckets inactive for 5+ minutes
- Works consistently across all adapters (Req, Tesla)

## [0.3.1] - 2025-09-30

### Added

- **PCI-compliant HTTP request/response logging** with automatic data sanitization
- `HTTPower.Logger` module for production-ready logging with security built-in
- **Correlation IDs** for distributed tracing - every request gets a unique ID (format: `req_abc123...`)
- **Request duration tracking** - logs include timing information in milliseconds
- **Automatic sanitization** of sensitive data in logs:
  - Credit card numbers (13-19 digits with optional spaces/dashes)
  - CVV codes (3-4 digits)
  - Authorization headers (Bearer tokens, Basic auth)
  - API keys and secret tokens
  - Password fields in JSON bodies
  - Configurable custom fields via application config
- **Configurable logging** via application config:
  - `enabled` - Enable/disable logging globally (default: true)
  - `level` - Log level: :debug, :info, :warning, :error (default: :info)
  - `sanitize_headers` - Additional headers to sanitize
  - `sanitize_body_fields` - Additional body fields to sanitize
- Comprehensive test suite for logging (42 new tests, 98.67% module coverage)
- Logging works consistently across all adapters (Req, Tesla)

### Changed

- Updated `HTTPower.Client` to integrate logging at request/response boundaries
- Request flow now includes: correlation ID generation → request logging → execution → response/error logging
- All HTTP operations now automatically log with sanitization (can be disabled via config)

### Technical Details

- Correlation IDs generated using cryptographically secure random bytes
- Sanitization uses regex patterns for credit cards, CVV codes
- JSON field sanitization supports nested maps and arrays
- Headers normalized to lowercase for consistent sanitization
- Large response bodies (>500 chars) are truncated in logs
- Logging sits above adapter layer - works identically with Req or Tesla

## [0.3.0] - 2025-09-30

### Added

- **Adapter pattern** supporting multiple HTTP clients (Req and Tesla)
- `HTTPower.Adapter` behavior for implementing custom adapters
- `HTTPower.Adapter.Req` - adapter using Req HTTP client
- `HTTPower.Adapter.Tesla` - adapter for existing Tesla users
- **`HTTPower.Test`** - adapter-agnostic testing module with zero external dependencies
  - `HTTPower.Test.setup/0` - enables mocking for current test
  - `HTTPower.Test.stub/1` - registers stub function to handle requests
  - `HTTPower.Test.json/2`, `html/2`, `text/2` - response helpers
  - `HTTPower.Test.transport_error/2` - simulates network failures (timeout, connection errors, etc.)
- `HTTPower.TestInterceptor` - clean separation of test logic from production code using compile-time checks
- Comprehensive test suite proving adapter independence (50 tests total)
- `adapter` option for specifying which adapter to use
- **Smart adapter detection** - automatically uses available adapter (Req preferred if both present)
- Both Req and Tesla are now optional dependencies - choose the one you need
- Example files moved to `docs/` directory

### Fixed

- **Critical**: Fixed double retry bug where Req's built-in retry ran alongside HTTPower's retry
- **Critical**: Fixed double error wrapping where `HTTPower.Error` structs were wrapped multiple times
- Req adapter now explicitly sets `retry: false` to disable Req's retry mechanism
- Retry logic now runs consistently once per request attempt
- Error handling now checks if errors are already wrapped before wrapping again

### Changed

- Internal architecture refactored to use adapter pattern (public API unchanged)
- `HTTPower.Client` now routes requests through adapters instead of calling Req directly
- Design principle updated from "Req-Based" to "Adapter-Based"
- Documentation updated to emphasize adapter flexibility and production features
- Refactored control flow to eliminate nested conditionals (removed `if` inside `with`, `case` inside `if`)
- Main test suite now uses `HTTPower.Test` instead of `Req.Test` for true adapter independence

### Technical Details

- Adapter abstraction allows production features (retry, circuit breaker, rate limiting) to work consistently across HTTP clients
- **Symmetric dependencies**: Both Req and Tesla are optional - install only what you need
- Smart adapter detection automatically selects available adapter (prefers Req if both present)
- Backward compatible: existing code continues to work (Req auto-detected if installed)
- Tesla users can now adopt HTTPower without pulling in Req dependency
- Clear error message if neither adapter is installed
- Test-mode blocking works seamlessly across both adapters
- All 50 tests passing (29 main + 9 Req adapter + 9 Tesla adapter + 3 transport error tests)

## [0.2.0] - 2025-01-09

### Added

- Client configuration with `HTTPower.new/1` for reusable HTTP clients
- Base URL support for configured clients with automatic path resolution
- Option merging between client defaults and per-request settings
- Support for all HTTP methods (GET, POST, PUT, DELETE) with client instances
- Comprehensive test coverage for client configuration functionality
- HTTP status code retry logic following industry standards (408, 429, 500, 502, 503, 504)
- Exponential backoff with jitter for intelligent retry timing
- Configurable retry parameters: `base_delay`, `max_delay`, `jitter_factor`
- Fast unit tests for retry decision logic separated from execution

### Improved

- Retry test suite performance improved by 70% (48s → 15s) through separation of concerns
- Refactored retry decision functions for better testability and maintainability

### Fixed

- Corrected changelog to accurately reflect implemented vs planned features
- Updated documentation to clarify current capabilities

## [0.1.0] - 2025-09-09

### Added

- Basic HTTP methods (GET, POST, PUT, DELETE) with clean API
- Test mode request blocking to prevent real HTTP requests during testing
- Req.Test integration for controlled HTTP testing and mocking
- Smart retry logic with configurable policies and error categorization
- Clean error handling that never raises exceptions
- SSL certificate verification with configurable options
- Proxy configuration support (system proxy and custom proxy settings)
- Request timeout management with sensible defaults
- Comprehensive error messages for common network issues
- Support for custom headers and request bodies
- Automatic Content-Type headers for POST requests
- Connection close headers for reliable request handling
- Mint.TransportError handling for detailed network error reporting
- Complete test suite with 100% coverage
- Full documentation with examples and API reference
- Hex package configuration for easy installation

### Technical Details

- Built on top of Req HTTP client for reliability
- Uses Mint for low-level HTTP transport (via Req)
- Supports HTTP/1.1 and HTTP/2 protocols
- Elixir 1.14+ compatibility
- Production-ready error handling and logging
- PCI DSS compliance considerations in design

[unreleased]: https://github.com/mdepolli/httpower/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/mdepolli/httpower/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mdepolli/httpower/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mdepolli/httpower/releases/tag/v0.1.0

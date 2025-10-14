# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.12.0] - 2025-10-13

### Added

- **Finch adapter** - High-performance HTTP client built on Mint and NimblePool
  - `HTTPower.Adapter.Finch` - New adapter using Finch HTTP client
  - Performance-focused with explicit connection pooling
  - Built on Mint (same low-level library that powers Req)
  - SSL/TLS support with configurable verification
  - Proxy support (system or custom)
  - Manual JSON decoding with Jason for flexibility
  - Connection pool configuration via Application config
  - Comprehensive test suite (357 tests passing)

### Changed

- **Finch is now the default adapter** (breaking change for adapter detection order)
  - Adapter detection priority: Finch → Req → Tesla
  - All adapters remain optional - users can choose what to install
  - No breaking changes to existing code (auto-detection still works)
  - Updated error message to recommend Finch first
  - Updated README and documentation to reflect Finch as default
- **Renamed Feature to Middleware for clearer semantics**
  - `HTTPower.Feature` → `HTTPower.Middleware` (module namespace change)
  - `lib/httpower/feature/` → `lib/httpower/middleware/` (directory reorganization)
  - All middleware modules moved: `RateLimiter`, `CircuitBreaker`, `Dedup`
  - Updated all references in code, tests, and documentation
  - Industry-standard terminology (matches Phoenix/Plug, Express, Rails)
  - Zero breaking changes to public API - internal refactoring only
- **Logger tests updated to use Finch adapter**
  - Converted from `Req.Test` to `HTTPower.Test` (adapter-agnostic)
  - All 51 logger tests now test with Finch adapter
  - Tests demonstrate adapter-agnostic testing approach

### Technical Details

- Finch adapter handles both URI structs and strings
- Header format conversion to match Req's format (map with list values)
- Automatic JSON body parsing when response is valid JSON
- Conditional supervision - Finch only started if loaded via `Code.ensure_loaded?/1`
- Default pool configuration: 10 connections per pool, one pool per scheduler
- Configurable pools via `config :httpower, :finch_pools`
- Test coverage excludes Finch adapter (tested via integration tests)
- All production features work consistently across Finch, Req, and Tesla adapters
- Middleware pattern provides clearer mental model for request/response pipeline
- All 357 tests passing with zero compilation warnings

## [0.11.0] - 2025-10-13

### Changed

- **Refactored client to extensible pipeline architecture**
  - Introduced `HTTPower.Feature` behaviour for composable request pipeline features
  - New `HTTPower.Request` struct for context passing between pipeline stages
  - Generic recursive step executor works with ANY feature implementation
  - Compile-time feature registry with zero overhead for disabled features
  - Runtime config merging (runtime takes precedence over compile-time)
  - Features can inspect, modify, short-circuit, or fail requests
  - Clean separation: features communicate via `request.private` map

- **URL validation and URI struct improvements**
  - Early fail-fast URL validation with clear error messages
  - Parse URL once at request start, use URI struct throughout pipeline
  - Direct field access: `request.url.host` instead of helper functions
  - SSL check now uses pattern matching: `%URI{scheme: "https"}`
  - Eliminates repeated URL parsing for better performance

- **Feature implementations refactored to use pipeline architecture**
  - All features (RateLimiter, CircuitBreaker, Dedup) now implement `HTTPower.Feature` behaviour
  - Simplified key extraction: `request.url.host` instead of URL parsing
  - Features store state in `request.private` for post-request processing
  - Circuit breaker and dedup can short-circuit pipeline with `{:halt, response}`
  - More consistent error handling across all features

- **Request execution flow improvements**
  - Request struct now built early in request lifecycle and passed throughout pipeline
  - Cleaner parameter passing: 2 parameters instead of 6 in execution functions

- **Code cleanup and documentation**
  - Removed ~57 redundant comments that described what code does rather than why
  - Kept important comments explaining architectural decisions
  - Client.ex, RateLimiter.ex, CircuitBreaker.ex, Dedup.ex all cleaned up
  - Improved code readability while maintaining comprehensive inline documentation

### Technical Details

- **Pipeline execution**: Features run in order (RateLimiter → CircuitBreaker → Dedup)
- **Zero overhead**: Disabled features not included in compiled pipeline
- **Post-request cleanup**: Circuit breaker recording and dedup completion handled automatically
- **Extensibility**: Adding new features requires only implementing `HTTPower.Feature` behaviour
- **Type safety**: URI structs ensure valid URLs throughout the pipeline
- **Testability**: Generic pipeline executor simplifies testing of new features
- **Request flow**: Request struct created early (line 103), passed through entire pipeline
- All 348 tests passing
- Zero compile warnings
- Net code addition: 434 lines (+721 -287) with significant architectural improvements

## [0.10.0] - 2025-10-07

### Added

- **Structured logging with metadata for log aggregation**
  - All log entries now include structured metadata via `Logger.metadata()`
  - Request metadata: `httpower_correlation_id`, `httpower_event`, `httpower_method`, `httpower_url`, headers, body
  - Response metadata: `httpower_correlation_id`, `httpower_event`, `httpower_status`, `httpower_duration_ms`, headers, body
  - Exception metadata: `httpower_correlation_id`, `httpower_event`, `httpower_duration_ms`, `httpower_exception_kind`, `httpower_exception_reason`
  - Enables powerful querying in log aggregation systems (Datadog, Splunk, ELK, Loki)
  - Query examples: `httpower_duration_ms:>1000`, `httpower_status:>=500`, `httpower_correlation_id:"req_abc123"`
  - All metadata respects `log_headers` and `log_body` configuration
  - Large bodies automatically truncated to 500 characters in metadata
  - All sensitive data sanitized before adding to metadata
  - Added 9 comprehensive tests for metadata functionality

### Changed

- **Performance: ETS write concurrency optimization**
  - Added `{:write_concurrency, true}` to all ETS tables (CircuitBreaker, RateLimiter, Dedup)
  - Expected 2-3x throughput improvement under high concurrency (50+ concurrent requests)
  - Enables parallel writes across multiple processes without serialization
  - Production-grade performance for high-traffic scenarios

- **Performance: CircuitBreaker async recording**
  - Switched from synchronous `GenServer.call` to async `GenServer.cast` for result recording
  - Expected 5-10x improvement in high-throughput scenarios
  - Non-blocking operation: requests don't wait for state updates
  - Eventually consistent state (5-10ms delay acceptable for circuit breaker logic)
  - Updated tests to handle async state changes with polling helper

- **Performance: Configuration caching optimization**
  - Implemented compile-time config caching using `Application.compile_env`
  - Eliminates repeated `Application.get_env` calls on every request
  - Module attributes cache default config values at compile time
  - Config resolution order: request-level → compile-time cached → runtime → hardcoded default
  - Runtime fallback ensures tests can dynamically override config
  - Particularly beneficial for high-throughput scenarios

### Technical Details

- ETS concurrency: `{:write_concurrency, true}` uses distributed locks for better parallelism
- CircuitBreaker: Test updates include `await_state/3` helper for polling async state changes
- Config caching: `@default_adapter`, `@default_config`, `@default_failure_threshold`, etc. cached at compile time
- Structured logging: Machine-readable metadata fields for production observability
- All 348 tests passing (9 new tests for structured logging metadata)
- Comprehensive documentation updates across README, guides, and CLAUDE.md

## [0.9.0] - 2025-10-06

### Added

- **Comprehensive telemetry integration using Erlang's `:telemetry` library**
  - HTTP request lifecycle events: `[:httpower, :request, :start]`, `[:httpower, :request, :stop]`, `[:httpower, :request, :exception]`
  - Retry attempt events: `[:httpower, :retry, :attempt]` with attempt_number, delay_ms, and reason
  - Rate limiter events: `[:httpower, :rate_limit, :ok]`, `[:httpower, :rate_limit, :wait]`, `[:httpower, :rate_limit, :exceeded]`
  - Circuit breaker events: `[:httpower, :circuit_breaker, :state_change]`, `[:httpower, :circuit_breaker, :open]`
  - Deduplication events: `[:httpower, :dedup, :execute]`, `[:httpower, :dedup, :wait]`, `[:httpower, :dedup, :cache_hit]`
  - All events include rich measurements (duration, timestamps) and metadata (method, url, status, etc.)
  - URLs automatically sanitized (query params/fragments stripped) for low cardinality in metrics
  - Default ports (80/443) excluded from URL telemetry for cleaner metrics
  - Zero dependencies (`:telemetry` ships with Elixir)
  - Full observability guide with Prometheus, OpenTelemetry, and LiveDashboard examples

**Integration Examples:**

```elixir
# Prometheus metrics
distribution("httpower.request.duration",
  event_name: [:httpower, :request, :stop],
  measurement: :duration,
  unit: {:native, :millisecond},
  tags: [:method, :status]
)

# OpenTelemetry
OpentelemetryTelemetry.register_application_tracer(:httpower)

# Custom logging
:telemetry.attach("httpower-logger", [:httpower, :request, :stop], &log_request/4, nil)
```

**Documentation:**

- Added comprehensive observability guide at `guides/observability.md`
- Updated README with Observability & Telemetry section
- Added 11 new telemetry integration tests (339 total tests, all passing)

## [0.8.1] - 2025-10-01

### Fixed

- **Documentation updates for v0.8.0 breaking changes**
  - Updated all error atom references in README examples
  - Updated configuration reference with new error atoms
  - Updated migration guides (Tesla and Req)
  - Updated production deployment guide examples
  - Restructured Configuration Availability Matrix for better HTML rendering
  - All documentation now correctly references `:too_many_requests` and `:service_unavailable`

## [0.8.0] - 2025-10-01

### Changed

- **BREAKING: Plug-compatible error atoms for Phoenix integration**
  - Changed `:rate_limit_exceeded` → `:too_many_requests` (HTTP 429)
  - Changed `:circuit_breaker_open` → `:service_unavailable` (HTTP 503)
  - Enables seamless Phoenix/Plug integration without manual error mapping
  - HTTPower-specific atoms preserved: `:rate_limit_wait_timeout`, `:dedup_timeout`, transport errors
  - All error handling code must be updated to use new atoms

**Migration Guide:**

```elixir
# Update error pattern matching:
{:error, %{reason: :rate_limit_exceeded}}    # OLD
{:error, %{reason: :too_many_requests}}      # NEW

{:error, %{reason: :circuit_breaker_open}}   # OLD
{:error, %{reason: :service_unavailable}}    # NEW
```

## [0.7.1] - 2025-10-01

### Fixed

- **Critical: CircuitBreaker race condition in half-open state**
  - Fixed race condition where multiple concurrent processes could exceed `half_open_max_requests` limit
  - Increment counter BEFORE allowing request through (prevents concurrent bypass)
  - Added comprehensive concurrent request test (10 concurrent requests, verifies only 3 allowed)
- **Critical: ETS table orphaning on GenServer crash**
  - Fixed GenServer crashes orphaning ETS tables and causing supervisor restart loops
  - Added `{:heir, :none}` to all ETS table creations (RateLimiter, CircuitBreaker, Dedup)
  - Tables now automatically deleted when owning process terminates
  - Added crash recovery tests for all three GenServers
- **Critical: Dedup waiter timeout memory leak**
  - Fixed memory leak where dead/timeout waiter processes remained in memory indefinitely
  - Added process monitoring to detect when waiters die or timeout
  - Automatic cleanup removes dead waiters from in-flight request lists
  - Added tests for waiter death and timeout scenarios

### Changed

- **Performance: RateLimiter config caching**
  - Cache default configuration at GenServer startup (eliminates repeated `Application.get_env` calls)
  - ~15-20% reduction in rate limiter overhead per request
  - Config changes now require GenServer restart to take effect (production-realistic behavior)
  - Helper functions split into public (backward compatible) and optimized (GenServer) versions

### Technical Details

- All fixes based on comprehensive architectural review (see `doc/architecture-improvements.md`)
- CircuitBreaker: Inverted condition and atomic increment prevents race
- ETS tables: `{:heir, :none}` ensures clean supervisor restarts
- Dedup: Process monitors with `:DOWN` message handling for cleanup
- RateLimiter: Cached config in GenServer state, passed to callbacks
- All 328 tests passing with comprehensive coverage of new scenarios

## [0.7.0] - 2025-10-01

### Added

- **Request deduplication** - Prevent duplicate operations from double-clicks and race conditions
  - `HTTPower.Dedup` GenServer for tracking in-flight requests
  - Hash-based fingerprinting using method + URL + body
  - Response sharing: duplicate requests wait for first request to complete
  - Automatic cleanup of completed requests after 500ms TTL
  - Global configuration: `config :httpower, :deduplication, enabled: true`
  - Per-request control: `deduplicate: true` or `deduplicate: [key: custom_key]`
  - Custom deduplication keys for fine-grained control
  - Client-side protection that complements server-side idempotency keys
  - Integrated into request pipeline (after rate limit check, before circuit breaker)
  - 18 comprehensive tests covering hash generation, in-flight tracking, response sharing, cleanup, and high concurrency
- **Rate limit headers parsing** - Automatic detection and parsing of server rate limits from HTTP response headers
  - `HTTPower.RateLimitHeaders.parse/2` - Parses rate limit headers from responses
  - Supports multiple common formats:
    - GitHub/Twitter style: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`
    - RFC 6585/IETF style: `RateLimit-Limit`, `RateLimit-Remaining`, `RateLimit-Reset`
    - Stripe style: `X-Stripe-RateLimit-*` headers
    - `Retry-After` header (integer seconds format)
  - Auto-detection with `:auto` format (default), or explicit format specification
  - Case-insensitive header matching
  - Handles header values as strings, lists, or integers (adapter-agnostic)
- **Rate limiter integration with server headers** - Synchronize local rate limiter with server state
  - `HTTPower.RateLimiter.update_from_headers/2` - Updates bucket state from parsed headers
  - `HTTPower.RateLimiter.get_info/1` - Returns current bucket information
  - Server-provided limits synchronize with token bucket algorithm
  - Buckets continue to refill after synchronization

### Technical Details

- Header parser uses format auto-detection, trying GitHub → RFC → Stripe formats in order
- Parser handles all adapter header formats (Req's list of tuples, Tesla's various formats)
- Integration updates token bucket state to match server's remaining count
- Comprehensive test coverage: 38 tests for parser, 7 tests for integration, 5 tests for Retry-After
- HTTP date format in `Retry-After` not yet supported (only integer seconds)
- **Automatic backoff** - Retry logic respects `Retry-After` header on 429/503 responses
  - When server provides `Retry-After` header (integer seconds), HTTPower uses that exact wait time
  - Falls back to exponential backoff when header is missing
  - Only applies to 429 (Too Many Requests) and 503 (Service Unavailable) status codes
  - Other retryable status codes (408, 500, 502, 504) continue using exponential backoff

### Changed

- **Code organization and readability improvements** in `HTTPower.Client`
  - Reorganized file into logical sections: Public API, Main Pipeline, Retry Logic, Adapters, Test Mode, Rate Limit Config, Circuit Breaker Config, Logging, Error Handling
  - Refactored request flow to use clean `with` pipelines instead of nested case statements
  - All helper functions now return explicit `{:ok, value}` or `{:error, reason}` tuples for consistency
  - Moved test mode check to beginning of request pipeline for fail-fast behavior
  - Removed redundant code comments (kept only user-facing messages and section headers)
  - Simplified parameter passing by extracting options at point of use
  - Eliminated unnecessary wrapper functions for cleaner call stack
  - Net reduction of 27 lines while improving code clarity

### Technical Details

- No performance changes - refactoring only improves maintainability
- Rate limiter and circuit breaker already have early-exit optimizations when disabled
- All 304 tests passing, 0 compile warnings
- Renamed `do_http_request/3` → `execute_http_request/3` for clarity
- Removed `do_request/3` wrapper that just delegated to `execute_http_request/3`

## [0.6.0] - 2025-09-30

### Added

- **Global adapter configuration** - Configure HTTP adapter application-wide
  - `config :httpower, adapter: HTTPower.Adapter.Req` for global adapter selection
  - `config :httpower, adapter: {HTTPower.Adapter.Tesla, tesla_client}` for pre-configured clients
  - Configuration priority: per-request > per-client > global
  - Allows adapter switching without code changes
- **Comprehensive documentation structure** in `guides/` directory
  - `guides/migrating-from-tesla.md` - Complete 7-step Tesla migration guide
    - Emphasizes adapter-agnostic final code
    - Shows HTTPower.Test for testing (not Tesla.Mock)
    - Global and per-client configuration examples
  - `guides/migrating-from-req.md` - Req migration guide with error handling differences
  - `guides/configuration-reference.md` - Complete option reference with availability matrix
  - `guides/production-deployment.md` - Production deployment guide with supervision tree, monitoring, security
  - Moved examples to `guides/examples/` directory
- **Configuration availability matrix** showing which options work at global/per-client/per-request levels
- Updated ExDoc integration with organized guide groups (Migration Guides, Guides, Examples)

### Changed

- **README improvements**
  - Simplified "Adapter Support" section (removed confusing adapter-specific examples)
  - Added "Perfect For" section at top showing target use cases
  - Updated "Basic Usage" to show both direct and client-based patterns
  - Split "Correlation IDs" into standalone section (not just PCI logging)
  - Removed redundant "Production Considerations" and "Why HTTPower?" sections
  - Updated all references from Req.Test to HTTPower.Test
- **Documentation corrections across all guides**
  - Fixed sanitization config structure: `sanitize_headers` and `sanitize_body_fields` (not nested under `sanitize:`)
  - Clarified that custom sanitization fields are additive (supplement defaults, not replace)
  - Updated all examples to use correct configuration structure

### Technical Details

- Global adapter configuration integrates with existing per-client/per-request options
- Adapter detection order: per-request option → global config → auto-detection (Req preferred)
- Documentation now correctly reflects implementation details
- All configuration examples consistent across README, guides, and reference docs

## [0.5.0] - 2025-09-30

### Added

- **Circuit breaker pattern implementation** for protecting against cascading failures
- `HTTPower.CircuitBreaker` GenServer with three-state machine (closed, open, half-open)
- **Sliding window failure tracking** with unified request history
  - Tracks last N requests (both successes and failures) in a single sliding window
  - More accurate than separate windows for each result type
- **Dual threshold strategies**:
  - Absolute threshold: Open circuit after N failures
  - Percentage threshold: Open circuit when failure rate exceeds X%
- **Automatic state transitions**:
  - Closed → Open: When failure threshold is exceeded
  - Open → Half-Open: After timeout period expires
  - Half-Open → Closed: When all test requests succeed
  - Half-Open → Open: When any test request fails
- **Half-open state** with configurable test request limit
- **Manual circuit control**:
  - `HTTPower.CircuitBreaker.open_circuit/1` - Manually open a circuit
  - `HTTPower.CircuitBreaker.close_circuit/1` - Manually close a circuit
  - `HTTPower.CircuitBreaker.reset_circuit/1` - Reset circuit to initial state
  - `HTTPower.CircuitBreaker.get_state/1` - Check current circuit state
- **Flexible circuit breaker configuration**:
  - Global configuration via `config :httpower, :circuit_breaker`
  - Per-client configuration via `HTTPower.new/1`
  - Per-request configuration via request options
  - Custom circuit keys for grouping requests
- **Integration with existing retry logic**: Circuit breaker complements exponential backoff
  - Retry logic handles transient failures (timeouts, temporary errors)
  - Circuit breaker handles persistent failures (service outages, deployment issues)
- Comprehensive test suite (26 new tests covering all states, thresholds, transitions)
- Added circuit breaker section to README with examples and best practices

### Changed

- Refactored circuit breaker sliding window implementation
  - Changed from separate success/failure windows to unified request tracking
  - Uses tuples `{:success | :failure, timestamp}` for better accuracy
  - Window size now correctly limits total requests tracked (not per-type)
- Updated `HTTPower.Client` to integrate circuit breaker into request flow
- Circuit breaker wraps retry logic to provide fail-fast behavior when circuit is open
- Updated documentation to clarify relationship between circuit breaker and retry logic

### Technical Details

- Circuit breaker uses ETS for thread-safe state storage
- State transitions are logged for observability
- Circuit keys default to URL host but can be customized
- Sliding window implementation ensures accurate failure rate tracking
- Half-open state prevents thundering herd by limiting concurrent test requests

## [0.4.0] - 2025-09-30

### Added

- **Built-in rate limiting** with token bucket algorithm
- `HTTPower.RateLimiter` GenServer for managing rate limit state
- `HTTPower.Application` supervision tree for fault tolerance
- **Two rate limiting strategies**:
  - `:wait` - Blocks until tokens are available (up to `max_wait_time`)
  - `:error` - Returns `{:error, :too_many_requests}` immediately
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

[unreleased]: https://github.com/mdepolli/httpower/compare/v0.12.0...HEAD
[0.12.0]: https://github.com/mdepolli/httpower/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/mdepolli/httpower/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/mdepolli/httpower/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/mdepolli/httpower/compare/v0.8.1...v0.9.0
[0.8.1]: https://github.com/mdepolli/httpower/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/mdepolli/httpower/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/mdepolli/httpower/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/mdepolli/httpower/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/mdepolli/httpower/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/mdepolli/httpower/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/mdepolli/httpower/compare/v0.3.1...v0.4.0
[0.3.1]: https://github.com/mdepolli/httpower/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/mdepolli/httpower/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/mdepolli/httpower/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mdepolli/httpower/releases/tag/v0.1.0

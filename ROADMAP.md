# HTTPower Roadmap

Production reliability layer for Elixir HTTP clients. Adds circuit breakers, rate limiting, request deduplication, smart retries, and PCI-compliant logging to Finch (default), Req, or Tesla.

## Current Status ✅

**Core Foundation (v0.1.0 - v0.15.1)**

- ✅ Basic HTTP methods (GET, POST, PUT, DELETE)
- ✅ Adapter pattern supporting Finch (default), Req, and Tesla HTTP clients
- ✅ All adapters optional, conditionally compiled via `Code.ensure_loaded?/1`
- ✅ Adapter-agnostic testing via `HTTPower.Test`
- ✅ Smart retry logic with exponential backoff and jitter (extracted to `HTTPower.Retry`)
- ✅ HTTP status code retry logic (408, 429, 500-504)
- ✅ Automatic backoff respecting Retry-After headers (429/503)
- ✅ Clean error handling (never raises exceptions)
- ✅ Plug-compatible error atoms for Phoenix integration
- ✅ SSL/Proxy configuration support
- ✅ Request timeout management
- ✅ Client configuration pattern with reusable configs
- ✅ PCI-compliant request/response logging with automatic sanitization
- ✅ Structured logging with metadata for log aggregation (Datadog, Splunk, ELK, Loki)
- ✅ Request correlation IDs for distributed tracing
- ✅ Request timing and duration tracking
- ✅ Built-in rate limiting with token bucket algorithm
- ✅ Adaptive rate limiting based on circuit breaker health
- ✅ Rate limit headers parsing and synchronization
- ✅ Per-endpoint and per-client rate limit configuration
- ✅ Circuit breaker pattern with three states (closed, open, half-open)
- ✅ Failure threshold tracking with sliding window
- ✅ Request deduplication with hash-based fingerprinting and response sharing
- ✅ Middleware pipeline architecture (compile-time assembly, zero overhead for disabled middleware)
- ✅ Intelligent middleware coordination (dedup bypasses rate limiter, adaptive rate limiting)
- ✅ Configuration profiles (payment_processing, high_volume_api, microservices_mesh)
- ✅ Comprehensive telemetry integration (HTTP lifecycle, retry, rate limiter, circuit breaker, dedup)
- ✅ Compile-time config caching, ETS write concurrency, async circuit breaker recording
- ✅ OTP supervision tree with Finch connection pool management
- ✅ Symmetric body encoding/decoding via `HTTPower.Codec` (`json:`, `form:`, `raw:` options)
- ✅ Consistent Content-Type-driven JSON response decoding across all adapters
- ✅ Comprehensive test suite (368 tests + 12 doctests, 86%+ coverage)

## Phase 1: Production Reliability ✅ COMPLETED

**Logging & Debugging Features** ✅

- ✅ HTTP request/response logging for debugging
- ✅ Sanitized logging that scrubs sensitive data (PCI compliance)
- ✅ Request timing and performance metrics (duration tracking)
- ✅ Configurable log levels (debug, info, warn, error)
- ✅ Request/response ID correlation for tracing (correlation IDs)
- ✅ Automatic sanitization of credit cards, CVV, passwords, API keys, auth tokens
- ✅ Configurable sanitization rules (custom headers and body fields)

**Rate Limiting** ✅ COMPLETED

- ✅ Built-in rate limiting to respect API limits
- ✅ Per-endpoint rate limit configuration
- ✅ Token bucket algorithm implementation
- ✅ Two strategies: wait (with timeout) or error
- ✅ ETS-based storage for high performance
- ✅ Custom bucket keys for flexible grouping

**Circuit Breaker Pattern** ✅ COMPLETED

- ✅ Circuit breaker for failing services
- ✅ Three states: closed, open, half-open
- ✅ Configurable failure thresholds (absolute and percentage)
- ✅ Sliding window for request tracking
- ✅ Half-open state with limited test requests
- ✅ Automatic state transitions based on success/failure
- ✅ Manual circuit control (open, close, reset)
- ✅ Per-client and per-endpoint circuit breaker keys
- ✅ Works seamlessly with existing retry logic

## Phase 2: Advanced Features

**Completed ✅**

- [x] **Request deduplication** ✅ (v0.7.0)
  - ✅ Hash-based deduplication (method + URL + body)
  - ✅ Response sharing - duplicate requests wait for in-flight request
  - ✅ Automatic cleanup with configurable TTL
  - ✅ Custom deduplication keys for fine-grained control

- [x] **Telemetry integration** ✅ (v0.9.0)
  - ✅ HTTP request lifecycle events (start, stop, exception)
  - ✅ Retry, rate limiter, circuit breaker, dedup events
  - ✅ Rich measurements and metadata
  - ✅ URL sanitization for low cardinality metrics
  - ✅ Observability guide with Prometheus, OpenTelemetry, LiveDashboard examples

- [x] **Rate limit headers parsing** ✅ (v0.7.0)
  - ✅ Support X-RateLimit-*, RateLimit-*, Retry-After headers
  - ✅ Dynamic rate limit adjustment based on server responses

- [x] **Middleware pipeline architecture** ✅ (v0.11.0-v0.13.0)
  - ✅ `HTTPower.Middleware` behaviour for composable pre-request middleware
  - ✅ Compile-time pipeline assembly with zero overhead for disabled middleware
  - ✅ Per-client and per-request middleware configuration
  - ✅ Custom middleware support via `@behaviour HTTPower.Middleware`
  - ✅ Middleware coordination (dedup bypasses rate limiter, adaptive rate limiting)

- [x] **Configuration profiles** ✅ (v0.13.0)
  - ✅ Pre-configured profiles: payment_processing, high_volume_api, microservices_mesh
  - ✅ Deep merge with explicit option overrides

- [x] **Symmetric body encoding/decoding** ✅ (HTTPower.Codec)
  - ✅ `json:` option for automatic JSON encoding with Content-Type/Accept headers
  - ✅ `form:` option for automatic URL-encoded form encoding with Content-Type header
  - ✅ `raw:` option to skip automatic response decoding
  - ✅ Content-Type-driven JSON response decoding consistent across all adapters
  - ✅ Adapter-independent: encoding/decoding lives above the adapter layer

**Next Up**

- [ ] **Post-response middleware pipeline** - Extend middleware to post-response transformations
  - Generic post-response hook system (currently hardcoded for circuit breaker/dedup)
  - Post-response middleware for logging, caching, response transformation
  - Lifecycle hooks (on_success, on_failure, on_retry)

- [ ] **Circuit state notifications/callbacks** - Enable alerting and monitoring
  - Callbacks for state transitions (closed → open, etc.)
  - Configurable notification handlers
  - Integration with monitoring systems

- [ ] **OAuth 2.0 token management** - Automatic token refresh and management
  - Automatic token refresh before expiry
  - Token storage and retrieval
  - Multiple auth provider support
  - Thread-safe token access

- [ ] **Response caching** - Intelligent HTTP caching
  - Cache-Control header respect
  - ETags and conditional requests (304 Not Modified)
  - Configurable cache backends (memory/Redis)
  - Per-request cache configuration
  - Automatic cache invalidation

**Future Enhancements**

- [ ] **Automatic pagination handling** - Simplify paginated API consumption
  - Common pagination patterns (offset, cursor, page number)
  - Lazy enumeration of all pages
  - Configurable page size and limits
- [ ] Response validation helpers
- [ ] Bulk operation batching

## Phase 3: Ecosystem Integration 🌐

- [ ] Prometheus metrics export
- [ ] Response streaming for large payloads

## Design Principles

1. **Production First**: Every feature must be production-ready with comprehensive tests
2. **Adapter-Based**: Support multiple HTTP clients (Finch, Req, Tesla) through adapter pattern, ensuring production features work consistently across all adapters
3. **Zero-Config Sensible Defaults**: Work great out of the box with Finch adapter, configure when needed
4. **Elixir Idiomatic**: Use proper Elixir patterns (GenServer, supervision, etc.)
5. **Never Break**: Comprehensive backward compatibility and smooth upgrades
6. **PCI Compliance**: Built-in security features for payment processing ✅

## Target Use Cases

- **Payment Processing**: PCI-compliant HTTP client for payment gateways
- **API Integration**: Reliable client for third-party API consumption
- **Microservices**: Inter-service communication with reliability patterns
- **High-Volume APIs**: Rate limiting and circuit breaking for scale
- **Financial Services**: Compliance and audit logging capabilities

## Success Metrics

- **Reliability**: 99.9%+ success rate for well-formed requests
- **Performance**: <10ms overhead over raw Req for simple requests
- **Adoption**: Used by 100+ Elixir applications in production
- **Documentation**: Complete guides for all major use cases
- **Community**: Active contributor community and ecosystem

---

_HTTPower: Because your HTTP requests deserve to be as powerful as they are reliable._
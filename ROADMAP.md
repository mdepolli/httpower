# HTTPower Roadmap

A reliable HTTP client library for Elixir with advanced reliability patterns for production applications. Works with Req or Tesla through an adapter pattern.

## Current Status ✅

**Core Foundation (v0.1.0 - v0.8.1)**

- ✅ Basic HTTP methods (GET, POST, PUT, DELETE)
- ✅ Adapter pattern supporting Req and Tesla HTTP clients
- ✅ Test mode request blocking with Req.Test integration
- ✅ Smart retry logic with exponential backoff and jitter
- ✅ HTTP status code retry logic (408, 429, 500-504)
- ✅ Automatic backoff respecting Retry-After headers (429/503)
- ✅ Clean error handling (never raises exceptions)
- ✅ Plug-compatible error atoms for Phoenix integration
- ✅ SSL/Proxy configuration support
- ✅ Request timeout management
- ✅ Client configuration pattern with reusable configs
- ✅ PCI-compliant request/response logging with automatic sanitization
- ✅ Request correlation IDs for distributed tracing
- ✅ Request timing and duration tracking
- ✅ Built-in rate limiting with token bucket algorithm
- ✅ Rate limit headers parsing and synchronization
- ✅ Per-endpoint and per-client rate limit configuration
- ✅ Circuit breaker pattern with three states (closed, open, half-open)
- ✅ Failure threshold tracking with sliding window
- ✅ Request deduplication with hash-based fingerprinting
- ✅ Comprehensive test suite (328 tests, 98%+ coverage)

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

## Phase 2: Advanced Features 🔮

**Priority 1: Core Reliability Enhancements**

- [x] **Request deduplication** ✅ - Prevent duplicate requests from double-clicks, retries, or race conditions
  - ✅ Hash-based deduplication (method + URL + body)
  - ✅ Response sharing - duplicate requests wait for in-flight request
  - ✅ Automatic cleanup with 500ms TTL
  - ✅ Custom deduplication keys for fine-grained control
  - ✅ Critical for payment processing and order creation

**Priority 2: Observability & Monitoring**

- [x] **Telemetry integration** ✅ - Complete observability with Elixir's :telemetry
  - ✅ HTTP request lifecycle events (start, stop, exception)
  - ✅ Retry attempt tracking with delay and reason
  - ✅ Rate limiter events (ok, wait, exceeded)
  - ✅ Circuit breaker state transitions and open events
  - ✅ Deduplication events (execute, wait, cache_hit)
  - ✅ Rich measurements and metadata for all events
  - ✅ URL sanitization for low cardinality metrics
  - ✅ Integration examples for Prometheus, OpenTelemetry, LiveDashboard
  - ✅ Comprehensive observability guide

**Priority 3: Smart Rate Limiting**

- [x] **Rate limit headers parsing** ✅ - Automatic detection from server responses
  - ✅ Support X-RateLimit-*, RateLimit-*, Retry-After headers
  - ✅ Dynamic rate limit adjustment based on server responses
  - ✅ Rate limit quota tracking and reporting
  - ✅ Automatic backoff when server indicates limits (respects Retry-After on 429/503)

**Priority 4: Circuit Breaker Enhancements**

- [ ] **Circuit state notifications/callbacks** - Enable alerting and monitoring
  - Callbacks for state transitions (closed → open, etc.)
  - Configurable notification handlers
  - Integration with monitoring systems

**Priority 5: Middleware & Extensibility**

- [ ] **Request/response middleware pipeline** - Composable request/response transformations
  - Middleware chain execution (pre-request, post-response)
  - Built-in middleware: logging, caching, authentication
  - Custom middleware support (user-defined transformations)
  - Per-client and per-request middleware configuration
  - Compatible with existing adapter system (Req, Tesla)

- [ ] **Plugin/hook system** - Extensibility points for custom behavior
  - Pre-request hooks (modify request before execution)
  - Post-response hooks (transform response data)
  - Error hooks (custom error handling/recovery)
  - Lifecycle hooks (on_success, on_failure, on_retry)
  - Plug-style composability

**Priority 6: Authentication & Caching**

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
  - Works with existing retry and rate limiting
- [ ] Response validation helpers
- [ ] Bulk operation batching

## Phase 3: Ecosystem Integration 🌐

## Design Principles

1. **Production First**: Every feature must be production-ready with comprehensive tests
2. **Adapter-Based**: Support multiple HTTP clients (Req, Tesla) through adapter pattern, ensuring production features work consistently across all adapters
3. **Zero-Config Sensible Defaults**: Work great out of the box with Req adapter, configure when needed
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
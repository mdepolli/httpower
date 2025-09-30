# HTTPower Roadmap

A reliable HTTP client library for Elixir with advanced reliability patterns for production applications. Works with Req or Tesla through an adapter pattern.

## Current Status ✅

**Core Foundation (v0.1.0 - v0.3.0)**

- ✅ Basic HTTP methods (GET, POST, PUT, DELETE)
- ✅ Adapter pattern supporting Req and Tesla HTTP clients
- ✅ Test mode request blocking with Req.Test integration
- ✅ Smart retry logic with exponential backoff and jitter
- ✅ HTTP status code retry logic (408, 429, 500-504)
- ✅ Clean error handling (never raises exceptions)
- ✅ SSL/Proxy configuration support
- ✅ Request timeout management
- ✅ Client configuration pattern with reusable configs
- ✅ PCI-compliant request/response logging with automatic sanitization
- ✅ Request correlation IDs for distributed tracing
- ✅ Request timing and duration tracking
- ✅ Built-in rate limiting with token bucket algorithm
- ✅ Per-endpoint and per-client rate limit configuration
- ✅ Circuit breaker pattern with three states (closed, open, half-open)
- ✅ Failure threshold tracking with sliding window
- ✅ Comprehensive test suite (141 tests, 67%+ coverage)

## Phase 1: Production Reliability 🚧

**Logging & Debugging Features** ✅ COMPLETED

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

- [ ] **Request deduplication** - Prevent duplicate requests from double-clicks, retries, or race conditions
  - Hash-based deduplication (method + URL + body)
  - Configurable time window
  - Option to return cached response or wait for in-flight request
  - Critical for payment processing and order creation

**Priority 2: Observability & Monitoring**

- [ ] **Telemetry integration** - OpenTelemetry support for distributed tracing
  - Instrument all HTTP requests with spans
  - Track circuit breaker state changes
  - Monitor rate limiter consumption
  - Request/response timing metrics
  - Integration with existing observability tools

**Priority 3: Smart Rate Limiting**

- [ ] **Rate limit headers parsing** - Automatic detection from server responses
  - Support X-RateLimit-*, RateLimit-*, Retry-After headers
  - Dynamic rate limit adjustment based on server responses
  - Rate limit quota tracking and reporting
  - Automatic backoff when server indicates limits

**Priority 4: Circuit Breaker Enhancements**

- [ ] **Circuit state notifications/callbacks** - Enable alerting and monitoring
  - Callbacks for state transitions (closed → open, etc.)
  - Configurable notification handlers
  - Integration with monitoring systems

**Priority 5: Developer Experience**

- [ ] **Automatic pagination handling** - Simplify paginated API consumption
  - Common pagination patterns (offset, cursor, page number)
  - Lazy enumeration of all pages
  - Configurable page size and limits
  - Works with existing retry and rate limiting

**Future Enhancements**

- [ ] Request/response middleware pipeline
- [ ] Pre/post request hooks
- [ ] Response validation helpers
- [ ] Bulk operation batching

## Phase 3: Ecosystem Integration 🌐

**Authentication & Caching**

- [ ] OAuth 2.0 token management with automatic refresh
- [ ] Response caching (memory/Redis)
  - Cache-Control header respect
  - ETags and conditional requests
  - Configurable cache backends

**Monitoring & Metrics**

- [ ] Prometheus metrics export
- [ ] Health check endpoints
- [ ] Performance benchmarking tools
- [ ] Request/response size tracking

## Version History

**v0.5.0** (Current) - Circuit Breaker
- Added circuit breaker pattern with three states (closed, open, half-open)
- Sliding window failure tracking with unified request history
- Dual threshold strategies (absolute and percentage)
- Manual circuit control and state inspection
- Phase 1 complete: All production reliability features shipped

**v0.4.0** - Rate Limiting
- Built-in rate limiting with token bucket algorithm
- Two strategies: wait (with timeout) or error
- Per-endpoint and per-client configuration
- ETS-based storage for high performance

**v0.3.1** - PCI-Compliant Logging
- PCI-compliant request/response logging with automatic sanitization
- Request correlation IDs for distributed tracing
- Request duration tracking and performance metrics
- Configurable sanitization rules for headers and body fields

**v0.3.0** - Adapter Pattern
- Adapter pattern supporting Req and Tesla HTTP clients
- Both adapters are optional dependencies
- Fixed critical double retry bug

**v0.2.0** - Smart Retries
- Client configuration pattern with `HTTPower.new/1`
- HTTP status code retry logic (408, 429, 500-504)
- Exponential backoff with jitter
- Improved retry test performance by 70%

**v0.1.0** - Initial Release
- Basic HTTP methods (GET, POST, PUT, DELETE)
- Test mode blocking with Req.Test integration
- Smart retry logic and clean error handling
- SSL/Proxy configuration support

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
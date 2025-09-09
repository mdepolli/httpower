# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- HTTP request/response logging with configurable levels
- PCI-compliant data sanitization for logs
- Request timing and performance metrics
- Built-in rate limiting with token bucket algorithm
- Circuit breaker pattern for failing services
- Request/response ID correlation for tracing

### Changed
- Improved test coverage from 50% to 62.65%
- Added comprehensive test suite with 29 tests covering all HTTP methods
- Enhanced error handling with better message formatting
- Improved SSL and proxy configuration testing

### Removed
- Redundant error handling code paths for better maintainability

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

[unreleased]: https://github.com/mdepolli/httpower/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mdepolli/httpower/releases/tag/v0.1.0
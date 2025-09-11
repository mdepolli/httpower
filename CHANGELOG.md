# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[unreleased]: https://github.com/mdepolli/httpower/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/mdepolli/httpower/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/mdepolli/httpower/releases/tag/v0.1.0

# Symmetric JSON & Form Body Handling

**Date:** 2026-03-18
**Status:** Draft
**Scope:** New `HTTPower.Codec` module, adapter changes, public API options, documentation

## Problem

HTTPower handles request encoding and response decoding inconsistently:

- **Request encoding:** Fully manual. Users must call `Jason.encode!/1` and set Content-Type themselves.
- **Response decoding:** Varies by adapter:
  - Finch: blindly tries `Jason.decode` on every response body regardless of Content-Type
  - Req: delegates to Req's built-in Content-Type-aware decoding
  - Tesla: depends on user's Tesla middleware stack (e.g., `Tesla.Middleware.JSON`)
- **Default POST Content-Type:** `application/x-www-form-urlencoded` is applied to all POST requests, even when the body isn't form-encoded.

This violates HTTPower's core design principle: production features should work consistently across all adapters.

## Solution

Introduce symmetric, adapter-independent body encoding and decoding via a new `HTTPower.Codec` module. Encoding is triggered by explicit options (`json:`, `form:`). Decoding is automatic based on response Content-Type, with an opt-out.

## Design Decisions

1. **Explicit encoding options** (`json:`, `form:`) rather than inferring from headers. Explicit intent avoids ambiguity — "did the user set that header intending auto-encode, or did they already encode it themselves?"
2. **Content-Type-driven response decoding** with opt-out (`raw: true`). If a server says "this is JSON," decode it. Users can bypass when they need raw bytes.
3. **JSON-only response decoding.** Form-urlencoded responses are rare enough that users can handle them manually.
4. **Drop default POST Content-Type.** Let encoding options set it. A bare `body:` POST gets no assumed Content-Type — the previous default of `application/x-www-form-urlencoded` was a lie unless the body was actually form-encoded.
5. **Codec consumes its options** before the adapter sees them. The `json:`, `form:`, and `raw:` keys are removed from opts during encoding, so adapters never receive them. They're also added to adapter drop-lists as a safety net.
6. **Codec lives above the adapter layer**, not as middleware. Encoding/decoding is data transformation, not a reliability pattern like rate limiting or circuit breaking.
7. **Never raises.** `encode_request` uses `Jason.encode/1` (not `encode!`) and converts failures to `{:error, %HTTPower.Error{reason: :json_encode_error}}`. This maintains HTTPower's "never raises" pattern.
8. **Case-insensitive header matching** for put_new behavior. When Codec sets `Content-Type` or `Accept`, it checks for existing headers case-insensitively (e.g., user-set `"content-type"` prevents Codec from adding `"Content-Type"`).
9. **Flat form data only.** The `form:` option uses `URI.encode_query/1`, which only handles flat key-value pairs. Nested data structures are not supported — users needing nested form encoding should use `body:` with `Plug.Conn.Query.encode/1` manually.

## Architecture

### New Module: `HTTPower.Codec`

```
lib/httpower/codec.ex
```

**Public functions:**

- `encode_request(request, opts)` — returns `{:ok, updated_request, updated_opts}` or `{:error, reason}`
- `decode_response(response, opts)` — returns updated response
- `json_content_type?(content_type)` — returns boolean (exported for testing)

### Request Encoding

`encode_request/2` inspects opts for encoding directives:

| Option | Action |
|--------|--------|
| `json: data` | `Jason.encode/1` the data, set `Content-Type: application/json` and `Accept: application/json` (put_new, case-insensitive — don't overwrite user-set headers), remove `json:` from opts |
| `form: data` | `URI.encode_query/1` the data (flat key-value only), set `Content-Type: application/x-www-form-urlencoded`, remove `form:` from opts |
| `body: data` | Pass through as-is, no headers set |
| Conflicting options | Return `{:error, %HTTPower.Error{reason: :conflicting_body_options}}` |
| JSON encode failure | Return `{:error, %HTTPower.Error{reason: :json_encode_error}}` |

Conflicting combinations: `json:` + `body:`, `json:` + `form:`, `form:` + `body:`.

**Body extraction note:** Currently, `Client.post/put/delete` extract the body via `Keyword.get(opts, :body)`. When `json:` or `form:` is used, the `:body` key is absent from opts, so the initial body passed to `Request.new/5` is `nil`. Codec then replaces `request.body` with the encoded value. This is correct behavior — `json:` and `form:` bypass the `:body` extraction path entirely.

### Response Decoding

`decode_response/2` inspects the response Content-Type header:

1. Extract Content-Type from response headers
2. Check if it matches JSON: `application/json` or any `+json` suffix (e.g., `application/vnd.api+json`)
3. If JSON and body is a non-empty binary: `Jason.decode/1`
   - On success: replace body with decoded value
   - On decode failure: leave body as raw binary (don't error — the server claimed JSON but sent garbage)
4. Skip decoding if:
   - `raw: true` in opts
   - Body is not binary (already decoded, e.g., from dedup cache hit)
   - Body is empty (`""` or `nil`)
   - Content-Type is not JSON

**Dedup cache hits:** When a request is served from the dedup cache via `{:halt, response}`, the response body may already be decoded (from the original request's Codec pass). `decode_response` handles this safely — the "body is not binary" check skips already-decoded values (maps, lists, etc.). This ensures `decode_response` is idempotent and can run on all code paths without special-casing.

### Integration Point in `HTTPower.Client`

```
User calls HTTPower.post(url, json: %{name: "Alice"})
  |
  v
Build %Request{} struct (body is nil since :body key absent)
  |
  v
Codec.encode_request/2          <-- NEW: encodes body, sets headers, consumes options
  |                                  Error? -> return {:error, reason} via with chain
  v
Middleware Pipeline (Dedup -> RateLimiter -> CircuitBreaker)
  |
  v
Retry -> Adapter (returns raw binary body)
  |
  v
Post-request hooks (circuit breaker recording, dedup completion)
  |
  v
Codec.decode_response/2         <-- NEW: decodes body based on Content-Type
  |                                  Runs on ALL paths including {:halt} from middleware
  v
Return to user
```

Encoding runs **before** the middleware pipeline so that:
- Dedup hashes the actual encoded body (correct deduplication)
- Middleware sees final headers

Decoding runs **after** post-request hooks so that:
- Circuit breaker sees raw status codes
- Dedup completion works on the raw response

**Error integration:** `Codec.encode_request/2` returns `{:ok, request, opts}` or `{:error, reason}`. This integrates into `Client.request/4`'s existing `with` chain as a new step after building the `%Request{}` struct and before the middleware pipeline. An encoding error (conflicting options, JSON encode failure) short-circuits the request immediately.

**Telemetry note:** After Codec encoding, `request.body` in telemetry metadata will contain the encoded JSON string rather than the original data structure. This is correct (telemetry should reflect what was actually sent) but is a subtle change for users inspecting body in telemetry handlers.

## Adapter Changes

### Finch Adapter (`lib/httpower/adapter/finch.ex`)

- **Remove** `parse_body/1` function (the blind `Jason.decode` on every response)
- Adapter returns raw binary body only

### Req Adapter (`lib/httpower/adapter/req.ex`)

- Pass `decode_body: false` to `Req.request/1` to disable Req's built-in response decoding (HTTPower.Codec handles it now). Note: this only disables content decoding (JSON, CSV, etc.), NOT decompression — Req's `decompress_body` step is separate and remains active.
- Add `json:`, `form:`, `raw:` to the opts drop-list as safety net

### Tesla Adapter (`lib/httpower/adapter/tesla.ex`)

- No code changes needed (already passes body through as-is)
- Documentation note: users should remove `Tesla.Middleware.JSON` from their stack to avoid double-decoding

### `HTTPower.Adapter.prepare_headers/2`

- Remove default `Content-Type: application/x-www-form-urlencoded` for POST requests
- POST requests with no encoding option and no explicit Content-Type header will have no Content-Type set
- Function is retained for nil-safety (`headers || %{}`) and as an extension point

### `HTTPower.Test`

- `HTTPower.Test` delegates to `HTTPower.Adapter.prepare_headers/2`. After removing the default POST Content-Type, test stubs for POST requests will no longer receive the implicit `Content-Type: application/x-www-form-urlencoded` header. This is correct behavior — tests should reflect production.
- **Remove `HTTPower.Test.parse_body/1`** — this function does the same blind `Jason.decode` as the Finch adapter. Since `HTTPower.Codec.decode_response` now handles decoding after the test interceptor returns, `parse_body` must be removed to avoid double-decoding in test mode.

## Public API

### New Options

All HTTP methods accept:

- `json: term()` — encode body as JSON, set JSON Content-Type and Accept headers
- `form: keyword() | map()` — encode body as form-urlencoded (flat key-value only), set form Content-Type
- `raw: boolean()` — when `true`, skip response body decoding (default: `false`)

### Usage Examples

```elixir
# JSON request + auto-decoded JSON response
{:ok, response} = HTTPower.post("https://api.example.com/users", json: %{name: "Alice"})
response.body  #=> %{"id" => 1, "name" => "Alice"}

# Form-encoded request
{:ok, response} = HTTPower.post("https://api.example.com/login",
  form: [username: "alice", password: "secret"])

# Raw binary body with explicit Content-Type
{:ok, response} = HTTPower.post("https://api.example.com/upload",
  body: raw_bytes,
  headers: %{"Content-Type" => "application/octet-stream"})

# Opt out of response decoding
{:ok, response} = HTTPower.get("https://api.example.com/data", raw: true)
response.body  #=> "{\"id\": 1, \"name\": \"Alice\"}"

# Works with pre-configured clients
client = HTTPower.new("https://api.example.com",
  headers: %{"Authorization" => "Bearer token"})
{:ok, response} = HTTPower.post(client, "/users", json: %{name: "Alice"})

# Error on conflicting options
{:error, error} = HTTPower.post(url, json: %{a: 1}, body: "raw")
error.reason  #=> :conflicting_body_options

# Error on un-encodable data
{:error, error} = HTTPower.post(url, json: self())
error.reason  #=> :json_encode_error
```

## Breaking Changes

1. **POST requests without encoding options no longer get a default Content-Type.** Previously, all POSTs defaulted to `Content-Type: application/x-www-form-urlencoded`. Now, only `form:` sets that header. Users passing `body:` for form data should switch to `form:` or set the header explicitly.

2. **Finch adapter no longer auto-decodes responses.** The blind `Jason.decode` on every response body is removed. Response decoding is now Content-Type-aware and handled by `HTTPower.Codec`. Responses from non-JSON endpoints that were previously decoded (e.g., a text endpoint returning `"123"` becoming the integer `123`) will now correctly remain as binary strings.

3. **Req adapter no longer uses Req's built-in content decoding.** HTTPower's Codec handles it instead, ensuring consistent behavior across all adapters. The decoded output should be functionally identical for JSON responses. Decompression is unaffected.

4. **Tesla users with `Tesla.Middleware.JSON` will get double-decoded bodies.** Existing Tesla users who have JSON middleware in their stack must remove it to avoid double-decoding (e.g., a JSON string could be decoded twice, producing incorrect results). This is documented in the migration guide and Tesla adapter docs.

5. **Telemetry `request.body` metadata shape change.** Users who inspect `request.body` in telemetry handlers will now see the encoded JSON string instead of the original data structure when `json:` is used.

## Testing Strategy

### Unit Tests (`test/httpower/codec_test.exs`)

- `json:` option encodes body and sets headers
- `json:` with un-encodable data returns error
- `form:` option encodes body and sets header
- Conflicting options return error
- `json:` doesn't overwrite user-set Content-Type or Accept headers (case-insensitive)
- Response decoding for `application/json`
- Response decoding for `application/vnd.api+json` and other `+json` types
- `raw: true` skips decoding
- Non-JSON Content-Type leaves body as-is
- Invalid JSON body left as raw binary (no error)
- Empty/nil body left as-is
- Non-binary body left as-is (idempotent for dedup cache hits)
- Options are consumed (removed from opts after encoding)

### Integration Tests

- End-to-end `json:` round-trip through each adapter
- End-to-end `form:` round-trip
- `body:` pass-through still works
- Dedup correctly deduplicates identical `json:` requests
- Dedup cache hit returns decoded body
- Client with `json:` option

### Adapter Tests

- Finch returns raw binary body (no more auto-decode)
- Req returns raw binary body (decode_body: false)
- Tesla unchanged behavior

## Documentation Updates

### Source Module Docs

| File | Changes |
|------|---------|
| `lib/httpower.ex` | Update moduledoc, examples for all HTTP methods, add `json:`/`form:`/`raw:` to option docs |
| `lib/httpower/codec.ex` | New file — full moduledoc with encoding/decoding behavior, examples, Content-Type detection |
| `lib/httpower/client.ex` | Document Codec integration in request flow |
| `lib/httpower/adapter.ex` | Update `prepare_headers` docs, remove Content-Type default |
| `lib/httpower/adapter/finch.ex` | Remove `parse_body` docs, note adapters return raw bodies |
| `lib/httpower/adapter/req.ex` | Document `decode_body: false` pass-through |
| `lib/httpower/adapter/tesla.ex` | Add note about removing `Tesla.Middleware.JSON` |
| `lib/httpower/response.ex` | Clarify body type expectations |
| `lib/httpower/request.ex` | Clarify body type after encoding |
| `lib/httpower/error.ex` | Add `message/1` clauses for `:conflicting_body_options` and `:json_encode_error` |
| `lib/httpower/test.ex` | Update docs to reflect removed default POST Content-Type |

### Guides

| File | Changes |
|------|---------|
| `guides/configuration-reference.md` | Add `json:`, `form:`, `raw:` options |
| `guides/migrating-from-req.md` | Note differences in JSON handling vs Req's built-in |
| `guides/migrating-from-tesla.md` | Note about removing `Tesla.Middleware.JSON`, classify as breaking change |
| `guides/production-deployment.md` | Update if it references body encoding |
| `guides/observability.md` | Update if it shows request/response examples, note telemetry body metadata change |

### Top-Level

| File | Changes |
|------|---------|
| `README.md` | Update usage examples |
| `CHANGELOG.md` | Breaking changes (all 5), new features, migration notes, telemetry metadata change |
| `CLAUDE.md` | Add `HTTPower.Codec` to module structure, update architecture, config options, request flow |
| `ROADMAP.md` | Mark JSON/form encoding as complete |

## Resolved Questions

1. **`connection: close` header.** CLAUDE.md states "All requests get connection: close header." Verified: this is not set in `prepare_headers` and was already removed in a prior release. CLAUDE.md should be updated to remove this stale claim.

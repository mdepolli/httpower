# `params:` Option for Query String Encoding

**Date:** 2026-03-19
**Status:** Approved
**Scope:** Add `params:` option to `HTTPower.Codec` for query string encoding

## Problem

HTTPower has no built-in query parameter support. Users must manually append query strings to URLs.

## Solution

Add a `params:` option that encodes a keyword list or map into the request URL's query string via `URI.encode_query/1`. Lives in `HTTPower.Codec.encode_request`, following the same pattern as `json:` and `form:`.

## Design

### Encoding behavior

- `params: [page: 1, role: "admin"]` → appends `?page=1&role=admin` to URL
- If URL already has query params (e.g., `?foo=bar`), appends with `&` separator
- Uses `URI.encode_query/1` — flat key-value only (keyword lists, maps, lists of two-element tuples)
- `params: []` is a no-op
- Consumed from opts after encoding (same as `json:`, `form:`)

### No conflict with body options

`params:` is orthogonal to body encoding. All combinations are valid:
- `params: [format: "json"], json: %{query: "elixir"}` — query string + JSON body
- `params: [page: 1], form: [q: "search"]` — query string + form body
- `params: [page: 1], body: "raw"` — query string + raw body
- `params: [page: 1]` alone — query string, no body

### Integration point

Same as existing encoding — `Codec.encode_request` runs before the middleware pipeline, so the final URL (with query params) is what dedup hashes and middleware sees.

### Adapter coordination

Add `:params` to Req adapter's drop-list to prevent Req from double-encoding via its own `put_params` step.

## Changes

| File | Change |
|------|--------|
| `lib/httpower/codec.ex` | Add params encoding in `encode_request` |
| `lib/httpower/adapter/req.ex` | Add `:params` to drop-list |
| `test/httpower/codec_test.exs` | Unit tests for params encoding |
| `test/httpower_test.exs` | Integration test |
| `lib/httpower.ex` | Add `params:` to option docs and examples |
| `CLAUDE.md` | Add `params` to config options |
| `CHANGELOG.md` | New feature entry |
| `guides/configuration-reference.md` | Add `params:` option |
| `README.md` | Update examples if relevant |

## Examples

```elixir
# Simple query params
HTTPower.get("https://api.example.com/users", params: [page: 1, per: 20])
# => GET https://api.example.com/users?page=1&per=20

# Combined with JSON body
HTTPower.post("https://api.example.com/search",
  params: [format: "json"],
  json: %{query: "elixir"})
# => POST https://api.example.com/search?format=json  (body: JSON)

# Merges with existing query params
HTTPower.get("https://api.example.com/users?active=true", params: [page: 1])
# => GET https://api.example.com/users?active=true&page=1

# Works with clients
client = HTTPower.new(base_url: "https://api.example.com")
HTTPower.get(client, "/users", params: [page: 1])
```

# Symmetric JSON & Form Body Handling Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add adapter-independent request encoding (`json:`, `form:`) and Content-Type-driven response decoding via a new `HTTPower.Codec` module.

**Architecture:** New `HTTPower.Codec` module handles all encoding/decoding above the adapter layer. Client calls `Codec.encode_request` before the middleware pipeline and `Codec.decode_response` after post-request hooks. Adapters are simplified to return raw binary bodies only.

**Tech Stack:** Elixir, Jason, URI, ExUnit

**Spec:** `docs/superpowers/specs/2026-03-18-symmetric-json-body-handling-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `lib/httpower/codec.ex` | Create | Request encoding, response decoding, Content-Type detection |
| `test/httpower/codec_test.exs` | Create | Unit tests for Codec |
| `lib/httpower/client.ex` | Modify | Integrate Codec into request flow |
| `lib/httpower/error.ex` | Modify | Add new error message clauses |
| `lib/httpower/adapter.ex` | Modify | Remove POST default Content-Type |
| `lib/httpower/adapter/finch.ex` | Modify | Remove `parse_body` |
| `lib/httpower/adapter/req.ex` | Modify | Add `decode_body: false`, update drop-list |
| `lib/httpower/test.ex` | Modify | Remove `parse_body` |
| `test/httpower/adapter/finch_test.exs` | Modify | Update assertions for raw body |
| `test/httpower/adapter/req_test.exs` | Modify | Update assertions for raw body |
| `test/httpower_test.exs` | Modify | Update existing tests, add integration tests |
| `lib/httpower.ex` | Modify | Update moduledoc, examples, option docs |
| `lib/httpower/response.ex` | Modify | Clarify body type in docs |
| `lib/httpower/request.ex` | Modify | Clarify body type in docs |
| `lib/httpower/adapter/tesla.ex` | Modify | Add doc note about Tesla.Middleware.JSON |
| `guides/configuration-reference.md` | Modify | Add new options |
| `guides/migrating-from-req.md` | Modify | Note JSON handling differences |
| `guides/migrating-from-tesla.md` | Modify | Note Tesla.Middleware.JSON removal |
| `README.md` | Modify | Update usage examples |
| `CHANGELOG.md` | Modify | Breaking changes, new features |
| `CLAUDE.md` | Modify | Add Codec to architecture, remove stale `connection: close` claim |
| `ROADMAP.md` | Modify | Mark JSON/form encoding as complete |

---

## Task 1: Add error message clauses to `HTTPower.Error`

**Files:**
- Modify: `lib/httpower/error.ex:25-34`

- [ ] **Step 1: Write failing test**

Open `test/httpower_test.exs` and find the error-related tests. If there are none for `Error.message/1`, add to `test/httpower/codec_test.exs` later. For now, just add the clauses since `Error.message/1` is `@doc false` and tested indirectly.

Add the two new clauses to `lib/httpower/error.ex` before the catch-all:

```elixir
def message(:conflicting_body_options),
  do: "Cannot use multiple body options (json:, form:, body:) simultaneously"

def message(:json_encode_error), do: "Failed to encode data as JSON"
```

- [ ] **Step 2: Verify compilation**

Run: `mix compile --warnings-as-errors`
Expected: Compiles successfully.

- [ ] **Step 3: Commit**

```bash
git add lib/httpower/error.ex
git commit -m "Add error messages for conflicting_body_options and json_encode_error"
```

---

## Task 2: Create `HTTPower.Codec` with request encoding

**Files:**
- Create: `lib/httpower/codec.ex`
- Create: `test/httpower/codec_test.exs`

- [ ] **Step 1: Write failing tests for `encode_request` — json option**

Create `test/httpower/codec_test.exs`:

```elixir
defmodule HTTPower.CodecTest do
  use ExUnit.Case, async: true

  alias HTTPower.{Codec, Request}

  defp build_request(method \\ :post, headers \\ %{}) do
    uri = URI.parse("https://api.example.com/users")
    Request.new(method, uri, nil, headers)
  end

  describe "encode_request/2 with json: option" do
    test "encodes map as JSON body and sets headers" do
      request = build_request()
      opts = [json: %{name: "Alice"}]

      assert {:ok, encoded, updated_opts} = Codec.encode_request(request, opts)
      assert encoded.body == ~s({"name":"Alice"})
      assert encoded.headers["Content-Type"] == "application/json"
      assert encoded.headers["Accept"] == "application/json"
      refute Keyword.has_key?(updated_opts, :json)
    end

    test "encodes list as JSON body" do
      request = build_request()
      opts = [json: [1, 2, 3]]

      assert {:ok, encoded, _opts} = Codec.encode_request(request, opts)
      assert encoded.body == "[1,2,3]"
    end

    test "does not overwrite user-set Content-Type (exact case)" do
      request = build_request(:post, %{"Content-Type" => "application/vnd.api+json"})
      opts = [json: %{a: 1}]

      assert {:ok, encoded, _opts} = Codec.encode_request(request, opts)
      assert encoded.headers["Content-Type"] == "application/vnd.api+json"
    end

    test "does not overwrite user-set content-type (lowercase)" do
      request = build_request(:post, %{"content-type" => "application/vnd.api+json"})
      opts = [json: %{a: 1}]

      assert {:ok, encoded, _opts} = Codec.encode_request(request, opts)
      assert encoded.headers["content-type"] == "application/vnd.api+json"
      refute Map.has_key?(encoded.headers, "Content-Type")
    end

    test "does not overwrite user-set Accept header" do
      request = build_request(:post, %{"Accept" => "text/plain"})
      opts = [json: %{a: 1}]

      assert {:ok, encoded, _opts} = Codec.encode_request(request, opts)
      assert encoded.headers["Accept"] == "text/plain"
    end

    test "returns error for un-encodable data" do
      request = build_request()
      opts = [json: self()]

      assert {:error, %HTTPower.Error{reason: :json_encode_error}} =
               Codec.encode_request(request, opts)
    end
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/httpower/codec_test.exs`
Expected: All fail — module `HTTPower.Codec` does not exist.

- [ ] **Step 3: Implement `encode_request` for json option**

Create `lib/httpower/codec.ex`:

```elixir
defmodule HTTPower.Codec do
  @moduledoc """
  Adapter-independent request encoding and response decoding.

  Handles symmetric body encoding (request) and decoding (response) above the
  adapter layer, ensuring consistent behavior across all HTTPower adapters.

  ## Request Encoding

  Use explicit options to encode request bodies:

  - `json: data` — encodes as JSON, sets `Content-Type: application/json` and
    `Accept: application/json`
  - `form: data` — encodes as form-urlencoded, sets
    `Content-Type: application/x-www-form-urlencoded`
  - `body: data` — pass-through, no encoding or headers set

  Only one encoding option may be used per request. Combining `json:` with `body:`,
  `form:` with `body:`, or `json:` with `form:` returns an error.

  ## Response Decoding

  Responses with a JSON Content-Type (`application/json` or any `+json` suffix like
  `application/vnd.api+json`) are automatically decoded. Opt out with `raw: true`.

  ## Examples

      # JSON request + auto-decoded response
      HTTPower.post("https://api.example.com/users", json: %{name: "Alice"})

      # Form-encoded request
      HTTPower.post("https://api.example.com/login",
        form: [username: "alice", password: "secret"])

      # Skip response decoding
      HTTPower.get("https://api.example.com/data", raw: true)
  """

  alias HTTPower.{Error, Request}

  @doc """
  Encodes the request body based on encoding options in `opts`.

  Returns `{:ok, updated_request, updated_opts}` on success, where encoding
  options (`json:`, `form:`) have been consumed (removed) from opts.

  Returns `{:error, %HTTPower.Error{}}` on failure (conflicting options or
  JSON encode error).
  """
  @spec encode_request(Request.t(), keyword()) ::
          {:ok, Request.t(), keyword()} | {:error, Error.t()}
  def encode_request(%Request{} = request, opts) do
    has_json = Keyword.has_key?(opts, :json)
    has_form = Keyword.has_key?(opts, :form)
    has_body = Keyword.has_key?(opts, :body)

    conflict_count = Enum.count([has_json, has_form, has_body], & &1)

    if conflict_count > 1 do
      {:error,
       %Error{
         reason: :conflicting_body_options,
         message: Error.message(:conflicting_body_options)
       }}
    else
      do_encode(request, opts, has_json, has_form)
    end
  end

  defp do_encode(request, opts, true, false) do
    data = Keyword.fetch!(opts, :json)

    case Jason.encode(data) do
      {:ok, encoded} ->
        request =
          request
          |> Map.put(:body, encoded)
          |> put_header_unless_set("Content-Type", "application/json")
          |> put_header_unless_set("Accept", "application/json")

        {:ok, request, Keyword.delete(opts, :json)}

      {:error, _} ->
        {:error,
         %Error{reason: :json_encode_error, message: Error.message(:json_encode_error)}}
    end
  end

  defp do_encode(request, opts, false, true) do
    data = Keyword.fetch!(opts, :form)

    encoded = URI.encode_query(data)

    request =
      request
      |> Map.put(:body, encoded)
      |> put_header_unless_set("Content-Type", "application/x-www-form-urlencoded")

    {:ok, request, Keyword.delete(opts, :form)}
  end

  defp do_encode(request, opts, false, false) do
    {:ok, request, opts}
  end

  # Sets a header on the request only if no header with the same name
  # (case-insensitive) already exists.
  defp put_header_unless_set(%Request{headers: headers} = request, key, value) do
    downcased = String.downcase(key)

    already_set? =
      Enum.any?(headers, fn {existing_key, _} ->
        String.downcase(existing_key) == downcased
      end)

    if already_set? do
      request
    else
      %{request | headers: Map.put(headers, key, value)}
    end
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/httpower/codec_test.exs`
Expected: All 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/httpower/codec.ex test/httpower/codec_test.exs
git commit -m "Add HTTPower.Codec with JSON request encoding"
```

---

## Task 3: Add form encoding to `HTTPower.Codec`

**Files:**
- Modify: `test/httpower/codec_test.exs`
- Modify: `lib/httpower/codec.ex` (already implemented above, just tests needed)

- [ ] **Step 1: Write failing tests for form encoding**

Add to `test/httpower/codec_test.exs`:

```elixir
describe "encode_request/2 with form: option" do
  test "encodes keyword list as form-urlencoded body" do
    request = build_request()
    opts = [form: [username: "alice", password: "secret"]]

    assert {:ok, encoded, updated_opts} = Codec.encode_request(request, opts)
    assert encoded.body == "username=alice&password=secret"
    assert encoded.headers["Content-Type"] == "application/x-www-form-urlencoded"
    refute Keyword.has_key?(updated_opts, :form)
  end

  test "encodes map as form-urlencoded body" do
    request = build_request()
    opts = [form: %{"key" => "value"}]

    assert {:ok, encoded, _opts} = Codec.encode_request(request, opts)
    assert encoded.body == "key=value"
  end

  test "does not overwrite user-set Content-Type" do
    request = build_request(:post, %{"content-type" => "custom/form"})
    opts = [form: [a: 1]]

    assert {:ok, encoded, _opts} = Codec.encode_request(request, opts)
    assert encoded.headers["content-type"] == "custom/form"
    refute Map.has_key?(encoded.headers, "Content-Type")
  end
end

describe "encode_request/2 with conflicting options" do
  test "json + body returns error" do
    request = build_request()
    opts = [json: %{a: 1}, body: "raw"]

    assert {:error, %HTTPower.Error{reason: :conflicting_body_options}} =
             Codec.encode_request(request, opts)
  end

  test "json + form returns error" do
    request = build_request()
    opts = [json: %{a: 1}, form: [b: 2]]

    assert {:error, %HTTPower.Error{reason: :conflicting_body_options}} =
             Codec.encode_request(request, opts)
  end

  test "form + body returns error" do
    request = build_request()
    opts = [form: [a: 1], body: "raw"]

    assert {:error, %HTTPower.Error{reason: :conflicting_body_options}} =
             Codec.encode_request(request, opts)
  end
end

describe "encode_request/2 with no encoding option" do
  test "passes through unchanged" do
    request = build_request()
    opts = [body: "raw data", timeout: 30]

    assert {:ok, ^request, ^opts} = Codec.encode_request(request, opts)
  end

  test "passes through with empty opts" do
    request = build_request()
    opts = []

    assert {:ok, ^request, ^opts} = Codec.encode_request(request, opts)
  end
end
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `mix test test/httpower/codec_test.exs`
Expected: All tests pass (form encoding and conflict detection already implemented).

- [ ] **Step 3: Commit**

```bash
git add test/httpower/codec_test.exs
git commit -m "Add form encoding and conflict detection tests for Codec"
```

---

## Task 4: Add response decoding to `HTTPower.Codec`

**Files:**
- Modify: `test/httpower/codec_test.exs`
- Modify: `lib/httpower/codec.ex`

- [ ] **Step 1: Write failing tests for `decode_response`**

Add to `test/httpower/codec_test.exs`:

```elixir
alias HTTPower.Response

defp build_response(status \\ 200, headers \\ %{}, body \\ nil) do
  %Response{status: status, headers: headers, body: body}
end

describe "decode_response/2 with JSON content type" do
  test "decodes application/json response" do
    response = build_response(200, %{"content-type" => ["application/json"]}, ~s({"a":1}))

    decoded = Codec.decode_response(response, [])
    assert decoded.body == %{"a" => 1}
  end

  test "decodes application/json with charset" do
    response =
      build_response(200, %{"content-type" => ["application/json; charset=utf-8"]}, ~s({"a":1}))

    decoded = Codec.decode_response(response, [])
    assert decoded.body == %{"a" => 1}
  end

  test "decodes application/vnd.api+json" do
    response =
      build_response(200, %{"content-type" => ["application/vnd.api+json"]}, ~s({"a":1}))

    decoded = Codec.decode_response(response, [])
    assert decoded.body == %{"a" => 1}
  end

  test "leaves invalid JSON as raw binary" do
    response = build_response(200, %{"content-type" => ["application/json"]}, "not json")

    decoded = Codec.decode_response(response, [])
    assert decoded.body == "not json"
  end
end

describe "decode_response/2 skips decoding" do
  test "when raw: true" do
    response = build_response(200, %{"content-type" => ["application/json"]}, ~s({"a":1}))

    decoded = Codec.decode_response(response, raw: true)
    assert decoded.body == ~s({"a":1})
  end

  test "when Content-Type is not JSON" do
    response = build_response(200, %{"content-type" => ["text/html"]}, "<h1>Hi</h1>")

    decoded = Codec.decode_response(response, [])
    assert decoded.body == "<h1>Hi</h1>"
  end

  test "when body is nil" do
    response = build_response(204, %{"content-type" => ["application/json"]}, nil)

    decoded = Codec.decode_response(response, [])
    assert decoded.body == nil
  end

  test "when body is empty string" do
    response = build_response(204, %{"content-type" => ["application/json"]}, "")

    decoded = Codec.decode_response(response, [])
    assert decoded.body == ""
  end

  test "when body is already decoded (not binary)" do
    response = build_response(200, %{"content-type" => ["application/json"]}, %{"a" => 1})

    decoded = Codec.decode_response(response, [])
    assert decoded.body == %{"a" => 1}
  end

  test "when no Content-Type header" do
    response = build_response(200, %{}, ~s({"a":1}))

    decoded = Codec.decode_response(response, [])
    assert decoded.body == ~s({"a":1})
  end
end

describe "json_content_type?/1" do
  test "matches application/json" do
    assert Codec.json_content_type?("application/json")
  end

  test "matches application/json with charset" do
    assert Codec.json_content_type?("application/json; charset=utf-8")
  end

  test "matches +json suffix" do
    assert Codec.json_content_type?("application/vnd.api+json")
  end

  test "does not match text/html" do
    refute Codec.json_content_type?("text/html")
  end

  test "does not match nil" do
    refute Codec.json_content_type?(nil)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test test/httpower/codec_test.exs`
Expected: Failures — `decode_response/2` and `json_content_type?/1` not defined.

- [ ] **Step 3: Implement `decode_response` and `json_content_type?`**

Add to `lib/httpower/codec.ex`:

```elixir
@doc """
Decodes the response body based on its Content-Type header.

JSON responses (`application/json` or `+json` suffix) are automatically
decoded. Skips decoding when:
- `raw: true` is in opts
- Body is not a binary (already decoded, e.g. from dedup cache hit)
- Body is empty or nil
- Content-Type is not JSON
"""
@spec decode_response(Response.t(), keyword()) :: Response.t()
def decode_response(%Response{} = response, opts) do
  if Keyword.get(opts, :raw, false) do
    response
  else
    maybe_decode_body(response)
  end
end

@doc """
Returns `true` if the given Content-Type string indicates a JSON format.

Matches `application/json` and any type with a `+json` suffix
(e.g., `application/vnd.api+json`). Ignores parameters like `charset=utf-8`.
"""
@spec json_content_type?(String.t() | nil) :: boolean()
def json_content_type?(nil), do: false

def json_content_type?(content_type) when is_binary(content_type) do
  # Extract the media type (before any parameters like charset)
  media_type =
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()

  media_type == "application/json" or String.ends_with?(media_type, "+json")
end

defp maybe_decode_body(%Response{body: body} = response)
     when is_binary(body) and body != "" do
  content_type = get_content_type(response.headers)

  if json_content_type?(content_type) do
    case Jason.decode(body) do
      {:ok, decoded} -> %{response | body: decoded}
      {:error, _} -> response
    end
  else
    response
  end
end

defp maybe_decode_body(response), do: response

defp get_content_type(headers) when is_map(headers) do
  # Headers are %{String.t() => [String.t()]}
  # Find content-type case-insensitively
  Enum.find_value(headers, fn {key, values} ->
    if String.downcase(key) == "content-type" do
      List.first(values)
    end
  end)
end

defp get_content_type(_), do: nil
```

Also add `alias HTTPower.Response` to the existing aliases at the top of the module.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test test/httpower/codec_test.exs`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add lib/httpower/codec.ex test/httpower/codec_test.exs
git commit -m "Add response decoding to HTTPower.Codec"
```

---

## Task 5: Adapter changes + Client integration (atomic)

These changes are done together because they create intermediate test failures if committed separately. Removing adapter-level decoding, the POST Content-Type default, and Test's parse_body all break tests that are only fixed once Codec is integrated into Client.

**Files:**
- Modify: `lib/httpower/adapter/finch.ex:139-165` — remove `parse_body`
- Modify: `lib/httpower/adapter/req.ex:71-109` — add `decode_body: false`, update drop-list
- Modify: `lib/httpower/adapter.ex:99-107` — remove POST default Content-Type
- Modify: `lib/httpower/test.ex:353-407` — remove `parse_body`
- Modify: `lib/httpower/client.ex:25-27,127-146,188-228` — integrate Codec
- Modify: `test/httpower/adapter/finch_test.exs:93-101` — remove/update POST Content-Type test
- Modify: `test/httpower/adapter/req_test.exs:93-101,376,397` — remove/update POST Content-Type test + SSL/proxy body assertions
- Modify: `test/httpower_test.exs:51-67` — remove POST Content-Type assertion

### Part A: Adapter changes

- [ ] **Step 1: Remove `parse_body` from Finch adapter**

In `lib/httpower/adapter/finch.ex`, change `convert_response` to use body directly:

```elixir
defp convert_response(%Finch.Response{status: status, headers: headers, body: body}) do
  %Response{
    status: status,
    headers: convert_headers(headers),
    body: body
  }
end
```

Remove the `parse_body/1` functions (lines 157-164).

Update moduledoc: remove "Manual JSON decoding for flexibility" from features list.

- [ ] **Step 2: Disable Req's built-in response decoding**

In `lib/httpower/adapter/req.ex`, add `decode_body: false` to `base_opts` in `build_req_opts`:

```elixir
base_opts = [
  method: method,
  url: url,
  headers: prepare_headers(headers, method),
  receive_timeout: timeout * 1000,
  retry: false,
  decode_body: false
]
```

Add `json:`, `form:`, `raw:` to the drop-list (alphabetical order with existing entries):

```elixir
additional_opts =
  Keyword.drop(opts, [
    :adapter,
    :adapter_config,
    :base_delay,
    :body,
    :circuit_breaker,
    :circuit_breaker_key,
    :deduplicate,
    :form,
    :headers,
    :jitter_factor,
    :json,
    :max_delay,
    :max_retries,
    :profile,
    :proxy,
    :rate_limit,
    :rate_limit_key,
    :raw,
    :request_steps,
    :retry_safe,
    :ssl_verify,
    :timeout
  ])
```

- [ ] **Step 3: Remove default POST Content-Type from `prepare_headers`**

Change `lib/httpower/adapter.ex`:

```elixir
@doc """
Prepares request headers, ensuring a valid map is returned.

Used by all adapters and the test interceptor to ensure consistent header
handling across the library.
"""
@spec prepare_headers(map() | nil, atom()) :: map()
def prepare_headers(headers, _method) do
  headers || %{}
end
```

- [ ] **Step 4: Remove `parse_body` from `HTTPower.Test`**

In `lib/httpower/test.ex`, change `conn_to_result` (line 353) to use body directly:

```elixir
defp conn_to_result(conn) do
  case conn.private[:httpower_transport_error] do
    nil ->
      {:ok,
       %HTTPower.Response{
         status: conn.status || 200,
         headers: format_headers(conn.resp_headers),
         body: conn.resp_body
       }}

    reason ->
      {:error,
       %HTTPower.Error{
         reason: :test_transport_error,
         message: "Simulated transport error: #{reason}"
       }}
  end
end
```

Remove the `parse_body/1` functions (lines 400-407).

### Part B: Client integration

- [ ] **Step 5: Add Codec alias to Client**

In `lib/httpower/client.ex` line 25:

```elixir
alias HTTPower.{Codec, Error, Request, Response}
```

- [ ] **Step 6: Integrate encode_request into the `request` function**

Modify `defp request/4` (lines 127-146):

```elixir
defp request(method, url, body, opts) do
  headers = Keyword.get(opts, :headers, %{})

  with {:ok, :allowed} <- check_test_mode_allows_request(opts),
       {:ok, %URI{} = uri} <- validate_url(url),
       %Request{} = request <- Request.new(method, uri, body, headers, opts),
       {:ok, %Request{} = request, opts} <- Codec.encode_request(request, opts),
       request = %{request | opts: opts},
       pipeline when is_list(pipeline) <- get_request_pipeline(opts) do
    fun = get_request_function(request, pipeline)
    execute_with_telemetry(request, fun)
  else
    {:error, %Error{}} = error ->
      error

    {:error, :network_blocked} ->
      {:error, %Error{reason: :network_blocked, message: "Network access blocked in test mode"}}

    {:error, reason} ->
      {:error, %Error{reason: reason, message: Error.message(reason)}}
  end
end
```

- [ ] **Step 7: Integrate decode_response into `get_request_function`**

Modify `get_request_function` (lines 188-228). Add `Codec.decode_response` on all success paths.

**Important ordering note:** `Dedup.complete` is called in `handle_post_request` with the raw (pre-decode) response. This means dedup cache stores raw binary bodies. When a cached response comes back via `{:halt, response}`, `Codec.decode_response` will decode it. This is correct because `decode_response` skips non-binary bodies, making it safe to run on all paths.

```elixir
defp get_request_function(%Request{} = request, pipeline) do
  fn ->
    result =
      case run_request_steps(request, pipeline) do
        {:ok, %Request{} = final_request} ->
          result = execute_http_with_retry(final_request)
          handle_post_request(final_request, result)
          decode_result(result, request.opts)

        {:halt, %Response{} = response} ->
          # Dedup cache hits and circuit breaker short-circuits come here.
          # decode_response safely handles already-decoded bodies (non-binary skip).
          {:ok, Codec.decode_response(response, request.opts)}

        {:error, %Error{}} = error ->
          error

        {:error, reason} ->
          {:error, %Error{reason: reason, message: Error.message(reason)}}
      end

    response_metadata =
      case result do
        {:ok, response} ->
          %{
            status: response.status,
            headers: response.headers,
            body: response.body,
            retry_count: Keyword.get(request.opts, :retry_count, 0)
          }

        {:error, %Error{reason: reason}} ->
          %{error_type: reason}

        {:error, reason} ->
          %{error_type: reason}
      end

    {result, Map.merge(request_metadata(request), response_metadata)}
  end
end

defp decode_result({:ok, %Response{} = response}, opts) do
  {:ok, Codec.decode_response(response, opts)}
end

defp decode_result(error, _opts), do: error
```

### Part C: Fix broken tests

- [ ] **Step 8: Fix POST Content-Type test assertions**

These specific tests assert the old default POST Content-Type and must be updated:

1. `test/httpower/adapter/finch_test.exs:93` — "adds default Content-Type for POST requests"
   → **Delete this test.** There is no longer a default Content-Type for POST.

2. `test/httpower/adapter/req_test.exs:93` — "adds default Content-Type for POST requests"
   → **Delete this test.** Same reason.

3. `test/httpower_test.exs:57-59` — assertion inside "post/2 with body and headers"
   → **Remove** the Content-Type assertion. The test sends `body: "test=data"` which no longer gets a default Content-Type.

- [ ] **Step 9: Fix Req adapter SSL/proxy tests that bypass TestInterceptor**

These tests use `Req.Test.stub` directly (bypassing HTTPower.Test) and assert decoded JSON bodies. With `decode_body: false`, Req no longer decodes, and since these tests go through the adapter directly (not through Client), Codec doesn't run either.

1. `test/httpower/adapter/req_test.exs:376` — asserts `body: %{"ssl_and_proxy" => true}`
   → Change to: `body: ~s({"ssl_and_proxy":true})`

2. `test/httpower/adapter/req_test.exs:397` — asserts `body: %{"custom_proxy_ssl" => true}`
   → Change to: `body: ~s({"custom_proxy_ssl":true})`

Note: Check the exact JSON string format Req returns when `decode_body: false` — it may include whitespace. Run the test and match the actual output.

- [ ] **Step 10: Fix any remaining test failures**

Run: `mix test`

Examine and fix any other tests that broke due to:
- Adapters returning raw binary bodies (but Codec decoding for JSON content-types through Client)
- Test stubs no longer auto-decoding (but Codec decoding at Client level)
- Removed default POST Content-Type

- [ ] **Step 11: Run full test suite**

Run: `mix test`
Expected: All tests pass.

- [ ] **Step 12: Commit**

```bash
git add lib/httpower/client.ex lib/httpower/adapter.ex lib/httpower/adapter/finch.ex lib/httpower/adapter/req.ex lib/httpower/test.ex test/
git commit -m "Integrate Codec, remove adapter-level decoding, drop POST default Content-Type"
```

---

## Task 6: Add integration tests for the full flow

**Files:**
- Modify: `test/httpower_test.exs`

- [ ] **Step 1: Write integration tests**

Add a new describe block to `test/httpower_test.exs`:

```elixir
describe "json: option" do
  test "encodes request body and decodes JSON response" do
    HTTPower.Test.stub(fn conn ->
      # Verify the request body was JSON-encoded
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      assert body == ~s({"name":"Alice"})

      # Verify Content-Type was set
      [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert content_type == "application/json"

      HTTPower.Test.json(conn, %{id: 1, name: "Alice"})
    end)

    assert {:ok, response} = HTTPower.post("https://api.example.com/users", json: %{name: "Alice"})
    assert response.status == 200
    assert response.body == %{"id" => 1, "name" => "Alice"}
  end

  test "works with GET requests" do
    HTTPower.Test.stub(fn conn ->
      HTTPower.Test.json(conn, %{users: ["alice"]})
    end)

    assert {:ok, response} = HTTPower.get("https://api.example.com/users")
    assert response.body == %{"users" => ["alice"]}
  end
end

describe "form: option" do
  test "encodes request body as form-urlencoded" do
    HTTPower.Test.stub(fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      assert body == "username=alice&password=secret"

      [content_type] = Plug.Conn.get_req_header(conn, "content-type")
      assert content_type == "application/x-www-form-urlencoded"

      HTTPower.Test.json(conn, %{ok: true})
    end)

    assert {:ok, _response} =
             HTTPower.post("https://api.example.com/login",
               form: [username: "alice", password: "secret"]
             )
  end
end

describe "raw: option" do
  test "skips response decoding" do
    HTTPower.Test.stub(fn conn ->
      HTTPower.Test.json(conn, %{a: 1})
    end)

    assert {:ok, response} = HTTPower.get("https://api.example.com/data", raw: true)
    assert is_binary(response.body)
  end
end

describe "conflicting body options" do
  test "json + body returns error" do
    assert {:error, %HTTPower.Error{reason: :conflicting_body_options}} =
             HTTPower.post("https://api.example.com/test", json: %{a: 1}, body: "raw")
  end
end

describe "body: option (pass-through)" do
  test "sends raw body without encoding" do
    HTTPower.Test.stub(fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      assert body == "raw data"
      HTTPower.Test.text(conn, "ok")
    end)

    assert {:ok, response} =
             HTTPower.post("https://api.example.com/upload",
               body: "raw data",
               headers: %{"Content-Type" => "text/plain"}
             )
    assert response.body == "ok"
  end
end

describe "edge cases" do
  test "json: nil encodes as JSON null" do
    HTTPower.Test.stub(fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      assert body == "null"
      HTTPower.Test.json(conn, %{ok: true})
    end)

    assert {:ok, _response} = HTTPower.post("https://api.example.com/test", json: nil)
  end

  test "form: [] encodes as empty string" do
    HTTPower.Test.stub(fn conn ->
      {:ok, body, _conn} = Plug.Conn.read_body(conn)
      assert body == ""
      HTTPower.Test.json(conn, %{ok: true})
    end)

    assert {:ok, _response} = HTTPower.post("https://api.example.com/test", form: [])
  end

  test "raw: true preserves through opts for decode_response" do
    HTTPower.Test.stub(fn conn ->
      HTTPower.Test.json(conn, %{a: 1})
    end)

    assert {:ok, response} = HTTPower.get("https://api.example.com/test", raw: true)
    assert is_binary(response.body)
  end
end
```

- [ ] **Step 2: Run the integration tests**

Run: `mix test test/httpower_test.exs`
Expected: All pass.

- [ ] **Step 3: Run full test suite**

Run: `mix test`
Expected: All pass.

- [ ] **Step 4: Commit**

```bash
git add test/httpower_test.exs
git commit -m "Add integration tests for json:, form:, raw:, and body: options"
```

---

## Task 7: Update documentation — source modules

**Files:**
- Modify: `lib/httpower.ex` (moduledoc, method docs)
- Modify: `lib/httpower/response.ex` (body type docs)
- Modify: `lib/httpower/request.ex` (body type docs)
- Modify: `lib/httpower/adapter/tesla.ex` (Tesla.Middleware.JSON note)
- Modify: `lib/httpower/client.ex` (moduledoc)

- [ ] **Step 1: Update `lib/httpower.ex` moduledoc**

Update the Basic Usage section (lines 19-35) to show `json:` and `form:` examples:

```elixir
## Basic Usage

    # GET request — JSON response auto-decoded
    HTTPower.get("https://api.example.com/users")

    # POST with JSON body
    HTTPower.post("https://api.example.com/users",
      json: %{name: "Alice", email: "alice@example.com"})

    # POST with form data
    HTTPower.post("https://api.example.com/login",
      form: [username: "alice", password: "secret"])

    # Raw binary body
    HTTPower.post("https://api.example.com/upload",
      body: raw_bytes,
      headers: %{"Content-Type" => "application/octet-stream"})

    # Skip response decoding
    HTTPower.get("https://api.example.com/data", raw: true)
```

Update the Configuration Options section (lines 50-57) to add:

```
- `json` - Data to encode as JSON request body (sets Content-Type and Accept headers)
- `form` - Data to encode as form-urlencoded request body (keyword list or map, flat only)
- `raw` - Skip response body decoding when true (default: false)
```

Update the Configured Clients example (line 99) to use `json:` instead of `body:`:

```elixir
HTTPower.post(client, "/users", json: %{name: "John"})
```

- [ ] **Step 2: Update `lib/httpower/response.ex`**

Add clarification to moduledoc about body type:

```elixir
@moduledoc """
HTTP response struct from HTTPower.

This struct completely abstracts away the underlying HTTP library
and provides a clean, consistent interface.

## Body Decoding

Response bodies with a JSON Content-Type (`application/json` or `+json` suffix)
are automatically decoded into Elixir data structures. All other content types
return the raw binary body. Use `raw: true` in request options to skip decoding.
"""
```

- [ ] **Step 3: Update Tesla adapter docs**

Add to the Tesla adapter moduledoc (after the "Tesla Client Middleware" section in `lib/httpower/adapter/tesla.ex`):

```elixir
## Important: JSON Middleware

If your Tesla client includes `Tesla.Middleware.JSON`, you should remove it
when wrapping with HTTPower. HTTPower handles JSON encoding/decoding via
`HTTPower.Codec`, and having both active will cause double-decoding:

    # Before (double-decoding risk)
    Tesla.client([Tesla.Middleware.JSON])

    # After (correct)
    Tesla.client([])  # HTTPower handles JSON via json: option
```

- [ ] **Step 4: Run doctests**

Run: `mix test`
Expected: All pass (some doctests may need updating if they show old API).

- [ ] **Step 5: Check formatting**

Run: `mix format --check-formatted`
Expected: No formatting issues.

- [ ] **Step 6: Commit**

```bash
git add lib/httpower.ex lib/httpower/response.ex lib/httpower/request.ex lib/httpower/adapter/tesla.ex lib/httpower/client.ex
git commit -m "Update source module docs for json:, form:, raw: options"
```

---

## Task 8: Update guides

**Files:**
- Modify: `guides/configuration-reference.md`
- Modify: `guides/migrating-from-req.md`
- Modify: `guides/migrating-from-tesla.md`
- Modify: `guides/production-deployment.md` (if references body encoding)
- Modify: `guides/observability.md` (if shows request/response examples)

- [ ] **Step 1: Read each guide to understand current content**

Read all five guide files.

- [ ] **Step 2: Update `guides/configuration-reference.md`**

Add `json:`, `form:`, `raw:` to the options reference section with descriptions and examples.

- [ ] **Step 3: Update `guides/migrating-from-req.md`**

Add a section noting that HTTPower now handles JSON encoding/decoding independently of Req:
- Req's `json:` option is not used — HTTPower's `json:` works the same way but at the HTTPower layer
- Req's response decoding is disabled — HTTPower.Codec handles it

- [ ] **Step 4: Update `guides/migrating-from-tesla.md`**

Add a section about removing `Tesla.Middleware.JSON`:
- HTTPower now handles JSON encoding/decoding via `json:` option
- Having both Tesla.Middleware.JSON and HTTPower.Codec active causes double-decoding
- Migration: remove Tesla.Middleware.JSON, use HTTPower's `json:` option instead

- [ ] **Step 5: Check other guides**

Review `production-deployment.md` and `observability.md` for any references that need updating.

- [ ] **Step 6: Commit**

```bash
git add guides/
git commit -m "Update guides for json:, form:, raw: options"
```

---

## Task 9: Update README, CHANGELOG, CLAUDE.md, ROADMAP.md

**Files:**
- Modify: `README.md`
- Modify: `CHANGELOG.md`
- Modify: `CLAUDE.md`
- Modify: `ROADMAP.md`

- [ ] **Step 1: Update `README.md`**

Update usage examples to show `json:` and `form:` options. Replace any manual `Jason.encode!` + Content-Type examples.

- [ ] **Step 2: Update `CHANGELOG.md`**

Add under `## [Unreleased]`:

```markdown
### Added
- `json:` option for request encoding — encodes data as JSON and sets Content-Type/Accept headers
- `form:` option for request encoding — encodes data as form-urlencoded and sets Content-Type header
- `raw:` option to skip automatic response body decoding
- `HTTPower.Codec` module for adapter-independent body encoding and response decoding
- Automatic Content-Type-driven JSON response decoding (supports `application/json` and `+json` suffix)
- New error reasons: `:conflicting_body_options`, `:json_encode_error`

### Changed
- Response decoding is now consistent across all adapters (Finch, Req, Tesla)
- POST requests no longer get a default `Content-Type: application/x-www-form-urlencoded` — use `form:` option or set the header explicitly

### Removed
- Finch adapter no longer blindly decodes all response bodies as JSON
- Req adapter's built-in response decoding is disabled (HTTPower.Codec handles it)

### Breaking Changes
- POST requests without `form:` or explicit Content-Type header no longer receive `application/x-www-form-urlencoded` default
- Finch adapter returns raw binary bodies — non-JSON responses previously auto-decoded (e.g., numeric strings) now remain as binary
- Tesla users with `Tesla.Middleware.JSON` must remove it to avoid double-decoding
- Telemetry `request.body` metadata contains encoded JSON string instead of original data structure when `json:` is used
```

- [ ] **Step 3: Update `CLAUDE.md`**

Add `HTTPower.Codec` to the Module Structure section. Update the Architecture diagram and Request Flow to show Codec integration. Add `json:`, `form:`, `raw:` to Configuration Options. Update the Header Handling section to remove the POST default Content-Type note. Remove the stale claim "All requests get connection: close header" — this was already removed in a prior release.

- [ ] **Step 4: Update `ROADMAP.md`**

In Phase 2, mark JSON/form body encoding/decoding as complete.

- [ ] **Step 5: Check formatting**

Run: `mix format --check-formatted`

- [ ] **Step 6: Commit**

```bash
git add README.md CHANGELOG.md CLAUDE.md ROADMAP.md
git commit -m "Update README, CHANGELOG, CLAUDE.md, and ROADMAP for Codec feature"
```

---

## Task 10: Final verification

- [ ] **Step 1: Run full test suite**

Run: `mix test`
Expected: All tests pass.

- [ ] **Step 2: Run with warnings as errors**

Run: `mix compile --warnings-as-errors`
Expected: No warnings.

- [ ] **Step 3: Check formatting**

Run: `mix format --check-formatted`
Expected: No formatting issues.

- [ ] **Step 4: Review diff**

Run: `git diff HEAD~N` (where N is the number of commits since start)
Verify: All changes are intentional, no debug code left, no accidental deletions.

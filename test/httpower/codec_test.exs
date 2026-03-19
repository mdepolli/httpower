defmodule HTTPower.CodecTest do
  use ExUnit.Case, async: true

  alias HTTPower.Codec
  alias HTTPower.Error
  alias HTTPower.Request

  defp build_request(method \\ :post, headers \\ %{}) do
    Request.new(method, URI.parse("https://api.example.com/users"), nil, headers)
  end

  describe "encode_request/2 with json: option" do
    test "encodes map and sets Content-Type and Accept headers" do
      request = build_request()
      data = %{name: "Alice", age: 30}

      assert {:ok, updated_request, updated_opts} = Codec.encode_request(request, json: data)

      assert updated_request.body == Jason.encode!(data)
      assert updated_request.headers["Content-Type"] == "application/json"
      assert updated_request.headers["Accept"] == "application/json"
      assert updated_opts == []
    end

    test "encodes list" do
      request = build_request()
      data = [1, 2, 3]

      assert {:ok, updated_request, updated_opts} = Codec.encode_request(request, json: data)

      assert updated_request.body == "[1,2,3]"
      assert updated_request.headers["Content-Type"] == "application/json"
      assert updated_opts == []
    end

    test "does not overwrite user-set Content-Type (exact case)" do
      request = build_request(:post, %{"Content-Type" => "application/vnd.api+json"})

      assert {:ok, updated_request, _opts} =
               Codec.encode_request(request, json: %{name: "Alice"})

      assert updated_request.headers["Content-Type"] == "application/vnd.api+json"
    end

    test "does not overwrite user-set content-type (lowercase)" do
      request = build_request(:post, %{"content-type" => "application/vnd.api+json"})

      assert {:ok, updated_request, _opts} =
               Codec.encode_request(request, json: %{name: "Alice"})

      refute Map.has_key?(updated_request.headers, "Content-Type")
      assert updated_request.headers["content-type"] == "application/vnd.api+json"
    end

    test "does not overwrite user-set Accept header" do
      request = build_request(:post, %{"Accept" => "application/vnd.api+json"})

      assert {:ok, updated_request, _opts} =
               Codec.encode_request(request, json: %{name: "Alice"})

      assert updated_request.headers["Accept"] == "application/vnd.api+json"
    end

    test "returns error for un-encodable data" do
      request = build_request()

      assert {:error, %Error{reason: :json_encode_error}} =
               Codec.encode_request(request, json: self())
    end

    test "removes :json from returned opts" do
      request = build_request()

      assert {:ok, _request, updated_opts} =
               Codec.encode_request(request, json: %{}, timeout: 5000)

      assert updated_opts == [timeout: 5000]
    end
  end

  describe "encode_request/2 with form: option" do
    test "encodes keyword list" do
      request = build_request()
      data = [name: "Alice", age: "30"]

      assert {:ok, updated_request, updated_opts} = Codec.encode_request(request, form: data)

      assert updated_request.body == URI.encode_query(data)
      assert updated_request.headers["Content-Type"] == "application/x-www-form-urlencoded"
      assert updated_opts == []
    end

    test "encodes map" do
      request = build_request()
      data = %{"name" => "Alice", "role" => "admin"}

      assert {:ok, updated_request, updated_opts} = Codec.encode_request(request, form: data)

      assert updated_request.body == URI.encode_query(data)
      assert updated_request.headers["Content-Type"] == "application/x-www-form-urlencoded"
      assert updated_opts == []
    end

    test "does not overwrite user-set content-type" do
      request = build_request(:post, %{"content-type" => "multipart/form-data"})

      assert {:ok, updated_request, _opts} =
               Codec.encode_request(request, form: [name: "Alice"])

      refute Map.has_key?(updated_request.headers, "Content-Type")
      assert updated_request.headers["content-type"] == "multipart/form-data"
    end

    test "removes :form from returned opts" do
      request = build_request()

      assert {:ok, _request, updated_opts} =
               Codec.encode_request(request, form: [name: "Alice"], timeout: 5000)

      assert updated_opts == [timeout: 5000]
    end
  end

  describe "encode_request/2 with conflicting options" do
    test "returns error for json + body" do
      request = build_request()

      assert {:error, %Error{reason: :conflicting_body_options}} =
               Codec.encode_request(request, json: %{name: "Alice"}, body: "raw")
    end

    test "returns error for json + form" do
      request = build_request()

      assert {:error, %Error{reason: :conflicting_body_options}} =
               Codec.encode_request(request, json: %{name: "Alice"}, form: [name: "Alice"])
    end

    test "returns error for form + body" do
      request = build_request()

      assert {:error, %Error{reason: :conflicting_body_options}} =
               Codec.encode_request(request, form: [name: "Alice"], body: "raw")
    end
  end

  defp build_response(status \\ 200, headers \\ %{}, body \\ nil) do
    %HTTPower.Response{status: status, headers: headers, body: body}
  end

  describe "decode_response/2 with JSON content type" do
    test "decodes application/json response" do
      response =
        build_response(200, %{"content-type" => ["application/json"]}, ~s({"key":"value"}))

      decoded = Codec.decode_response(response, [])

      assert decoded.body == %{"key" => "value"}
    end

    test "decodes application/json; charset=utf-8" do
      response =
        build_response(
          200,
          %{"content-type" => ["application/json; charset=utf-8"]},
          ~s({"hello":"world"})
        )

      decoded = Codec.decode_response(response, [])

      assert decoded.body == %{"hello" => "world"}
    end

    test "decodes application/vnd.api+json" do
      response =
        build_response(
          200,
          %{"content-type" => ["application/vnd.api+json"]},
          ~s({"data":{"id":"1"}})
        )

      decoded = Codec.decode_response(response, [])

      assert decoded.body == %{"data" => %{"id" => "1"}}
    end

    test "leaves invalid JSON as raw binary" do
      response = build_response(200, %{"content-type" => ["application/json"]}, "not json at all")

      decoded = Codec.decode_response(response, [])

      assert decoded.body == "not json at all"
    end
  end

  describe "decode_response/2 skips decoding" do
    test "when raw: true" do
      response = build_response(200, %{"content-type" => ["application/json"]}, ~s({"a":1}))

      decoded = Codec.decode_response(response, raw: true)

      assert decoded.body == ~s({"a":1})
    end

    test "when Content-Type is not JSON" do
      response = build_response(200, %{"content-type" => ["text/html"]}, "<html></html>")

      decoded = Codec.decode_response(response, [])

      assert decoded.body == "<html></html>"
    end

    test "when body is nil" do
      response = build_response(204, %{"content-type" => ["application/json"]}, nil)

      decoded = Codec.decode_response(response, [])

      assert decoded.body == nil
    end

    test "when body is empty string" do
      response = build_response(200, %{"content-type" => ["application/json"]}, "")

      decoded = Codec.decode_response(response, [])

      assert decoded.body == ""
    end

    test "when body is already decoded (a map)" do
      already_decoded = %{"already" => "decoded"}
      response = build_response(200, %{"content-type" => ["application/json"]}, already_decoded)

      decoded = Codec.decode_response(response, [])

      assert decoded.body == already_decoded
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

    test "matches application/json; charset=utf-8" do
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

  describe "encode_request/2 with no encoding option" do
    test "passes through unchanged when body: is present" do
      request = build_request()

      assert {:ok, updated_request, updated_opts} =
               Codec.encode_request(request, body: "raw payload")

      assert updated_request == request
      assert updated_opts == [body: "raw payload"]
    end

    test "passes through unchanged with empty opts" do
      request = build_request()

      assert {:ok, updated_request, updated_opts} = Codec.encode_request(request, [])

      assert updated_request == request
      assert updated_opts == []
    end

    test "passes through unchanged with unrelated opts" do
      request = build_request()

      assert {:ok, updated_request, updated_opts} =
               Codec.encode_request(request, timeout: 5000, max_retries: 2)

      assert updated_request == request
      assert updated_opts == [timeout: 5000, max_retries: 2]
    end
  end

  describe "encode_request/2 with params: option" do
    test "appends query params to URL" do
      request = build_request(:get)
      opts = [params: [page: 1, per: 20]]

      assert {:ok, encoded, updated_opts} = Codec.encode_request(request, opts)
      assert encoded.url.query == "page=1&per=20"
      refute Keyword.has_key?(updated_opts, :params)
    end

    test "merges with existing query string" do
      uri = URI.parse("https://api.example.com/users?active=true")
      request = Request.new(:get, uri)

      assert {:ok, encoded, _opts} = Codec.encode_request(request, params: [page: 1])
      assert encoded.url.query == "active=true&page=1"
    end

    test "accepts a map" do
      request = build_request(:get)

      assert {:ok, encoded, _opts} =
               Codec.encode_request(request, params: %{"key" => "value"})

      assert encoded.url.query == "key=value"
    end

    test "empty params is a no-op" do
      request = build_request(:get)

      assert {:ok, encoded, updated_opts} = Codec.encode_request(request, params: [])
      assert encoded.url.query == nil
      refute Keyword.has_key?(updated_opts, :params)
    end

    test "combines with json: option" do
      request = build_request(:post)
      opts = [params: [format: "json"], json: %{query: "elixir"}]

      assert {:ok, encoded, updated_opts} = Codec.encode_request(request, opts)
      assert encoded.url.query == "format=json"
      assert encoded.body == ~s({"query":"elixir"})
      assert encoded.headers["Content-Type"] == "application/json"
      refute Keyword.has_key?(updated_opts, :params)
      refute Keyword.has_key?(updated_opts, :json)
    end

    test "combines with form: option" do
      request = build_request(:post)
      opts = [params: [page: 1], form: [q: "search"]]

      assert {:ok, encoded, updated_opts} = Codec.encode_request(request, opts)
      assert encoded.url.query == "page=1"
      assert encoded.body == "q=search"
      refute Keyword.has_key?(updated_opts, :params)
      refute Keyword.has_key?(updated_opts, :form)
    end
  end
end

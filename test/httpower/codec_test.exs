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
end

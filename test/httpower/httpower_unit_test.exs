defmodule HTTPower.UnitTest do
  @moduledoc """
  Unit tests for HTTPower public API module.

  These tests focus on improving coverage for:
  - 3-arity HTTP method calls (client, path, opts)
  - URL building logic with various path formats
  - Option merging between client and request options
  - Header merging logic
  """

  use ExUnit.Case, async: true

  setup_all do
    Application.put_env(:httpower, :test_mode, true)
    :ok
  end

  setup do
    HTTPower.Test.setup()
    :ok
  end

  describe "HTTPower.new/1" do
    test "creates client with base_url only" do
      client = HTTPower.new(base_url: "https://api.example.com")

      assert %HTTPower{base_url: "https://api.example.com", options: []} = client
    end

    test "creates client with base_url and options" do
      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          timeout: 30,
          max_retries: 5
        )

      assert %HTTPower{base_url: "https://api.example.com"} = client
      assert client.options[:timeout] == 30
      assert client.options[:max_retries] == 5
    end

    test "creates client with headers" do
      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"Authorization" => "Bearer token"}
        )

      assert client.options[:headers] == %{"Authorization" => "Bearer token"}
    end

    test "creates client without base_url" do
      client = HTTPower.new(timeout: 30)

      assert %HTTPower{base_url: nil, options: [timeout: 30]} = client
    end

    test "creates empty client" do
      client = HTTPower.new()

      assert %HTTPower{base_url: nil, options: []} = client
    end
  end

  describe "3-arity GET: get(client, path, opts)" do
    test "makes request with client, path, and additional options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"X-Client-Header" => "client-value"}
        )

      assert {:ok, response} =
               HTTPower.get(client, "/users", headers: %{"X-Request-Header" => "request-value"})

      assert response.status == 200
    end

    test "merges client headers with request headers" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        # Both headers should be present
        assert headers["x-client-header"] == "client-value"
        assert headers["x-request-header"] == "request-value"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"X-Client-Header" => "client-value"}
        )

      assert {:ok, _response} =
               HTTPower.get(client, "/test", headers: %{"X-Request-Header" => "request-value"})
    end

    test "request headers override client headers" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        # Request header should override client header
        assert headers["authorization"] == "Bearer request-token"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"Authorization" => "Bearer client-token"}
        )

      assert {:ok, _response} =
               HTTPower.get(client, "/test",
                 headers: %{"Authorization" => "Bearer request-token"}
               )
    end

    test "request options override client options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          timeout: 30,
          max_retries: 3
        )

      # Request options should take precedence
      assert {:ok, _response} = HTTPower.get(client, "/test", timeout: 60, max_retries: 5)
    end
  end

  describe "3-arity POST: post(client, path, opts)" do
    test "makes POST request with client, path, and options" do
      HTTPower.Test.stub(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body == "name=John"
        HTTPower.Test.json(conn, %{created: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, response} = HTTPower.post(client, "/users", body: "name=John")
      assert response.status == 200
      assert response.body == %{"created" => true}
    end

    test "merges headers for POST requests" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        assert headers["x-api-key"] == "secret"
        assert headers["content-type"] == "application/json"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"X-API-Key" => "secret"}
        )

      assert {:ok, _} =
               HTTPower.post(client, "/data",
                 body: Jason.encode!(%{foo: "bar"}),
                 headers: %{"Content-Type" => "application/json"}
               )
    end
  end

  describe "3-arity PUT: put(client, path, opts)" do
    test "makes PUT request with client, path, and options" do
      HTTPower.Test.stub(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body == "name=Jane"
        HTTPower.Test.json(conn, %{updated: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, response} = HTTPower.put(client, "/users/1", body: "name=Jane")
      assert response.body == %{"updated" => true}
    end
  end

  describe "3-arity DELETE: delete(client, path, opts)" do
    test "makes DELETE request with client, path, and options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.text(conn, "", status: 204)
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, response} = HTTPower.delete(client, "/users/1", [])
      assert response.status == 204
    end

    test "passes custom headers with DELETE" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        assert headers["x-delete-reason"] == "spam"
        HTTPower.Test.text(conn, "", status: 204)
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, _} =
               HTTPower.delete(client, "/users/1", headers: %{"X-Delete-Reason" => "spam"})
    end
  end

  describe "URL building with various path formats" do
    test "builds URL with nil base_url" do
      HTTPower.Test.stub(fn conn ->
        # Should use full path as-is
        assert conn.request_path == "/users"
        HTTPower.Test.json(conn, %{success: true})
      end)

      # No base_url
      client = HTTPower.new()

      assert {:ok, _} = HTTPower.get(client, "https://api.example.com/users")
    end

    test "builds URL with empty path" do
      HTTPower.Test.stub(fn conn ->
        # Should just use base_url
        assert conn.host == "api.example.com"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, _} = HTTPower.get(client, "")
    end

    test "builds URL with leading slash in path" do
      HTTPower.Test.stub(fn conn ->
        assert conn.request_path == "/users"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, _} = HTTPower.get(client, "/users")
    end

    test "builds URL without leading slash in path" do
      HTTPower.Test.stub(fn conn ->
        assert conn.request_path == "/users"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      # Should add slash automatically
      assert {:ok, _} = HTTPower.get(client, "users")
    end

    test "builds URL with base_url ending in slash" do
      HTTPower.Test.stub(fn conn ->
        # With trailing slash in base_url and no leading slash in path,
        # we get a double slash which is valid (//users)
        HTTPower.Test.json(conn, %{success: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com/")

      # Should still work, even if it creates //users
      assert {:ok, _} = HTTPower.get(client, "users")
    end

    test "builds URL with nested path" do
      HTTPower.Test.stub(fn conn ->
        assert conn.request_path == "/api/v1/users"
        HTTPower.Test.json(conn, %{success: true})
      end)

      client = HTTPower.new(base_url: "https://api.example.com")

      assert {:ok, _} = HTTPower.get(client, "/api/v1/users")
    end
  end

  describe "option merging logic" do
    test "merges all client options with request options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      client =
        HTTPower.new(
          base_url: "https://api.example.com",
          timeout: 30,
          max_retries: 3,
          ssl_verify: false
        )

      # All options should be passed through
      assert {:ok, _} = HTTPower.get(client, "/test", retry_safe: true)
    end

    test "empty headers merge correctly" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      # Client with headers, request without
      client1 =
        HTTPower.new(
          base_url: "https://api.example.com",
          headers: %{"X-Client" => "value"}
        )

      assert {:ok, _} = HTTPower.get(client1, "/test", [])

      # Client without headers, request with
      client2 = HTTPower.new(base_url: "https://api.example.com")
      assert {:ok, _} = HTTPower.get(client2, "/test", headers: %{"X-Request" => "value"})

      # Neither has headers
      client3 = HTTPower.new(base_url: "https://api.example.com")
      assert {:ok, _} = HTTPower.get(client3, "/test", [])
    end
  end

  describe "test_mode?/0" do
    test "returns true when test mode is enabled" do
      Application.put_env(:httpower, :test_mode, true)
      assert HTTPower.test_mode?() == true
    end

    test "returns false when test mode is disabled" do
      Application.put_env(:httpower, :test_mode, false)
      assert HTTPower.test_mode?() == false

      # Restore for other tests
      Application.put_env(:httpower, :test_mode, true)
    end

    test "returns false by default when not configured" do
      # Temporarily remove config
      original = Application.get_env(:httpower, :test_mode)
      Application.delete_env(:httpower, :test_mode)

      assert HTTPower.test_mode?() == false

      # Restore
      Application.put_env(:httpower, :test_mode, original)
    end
  end
end

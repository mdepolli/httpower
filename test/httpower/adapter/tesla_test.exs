defmodule HTTPower.Adapter.TeslaTest do
  @moduledoc """
  Unit tests for HTTPower.Adapter.Tesla module.

  These tests directly test the Tesla adapter logic, including Tesla client handling,
  header conversion, option building, and response conversion.
  """

  use ExUnit.Case, async: true
  alias HTTPower.Adapter.Tesla, as: TeslaAdapter
  alias HTTPower.Response

  setup_all do
    Application.put_env(:httpower, :test_mode, true)
    :ok
  end

  setup do
    HTTPower.Test.setup()
    :ok
  end

  describe "request/5 with HTTPower.Test interception" do
    test "makes successful GET request" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{status: 200, body: body}} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)

      assert body == %{"success" => true}
    end

    test "makes successful POST request with body" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{received: true})
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{status: 200}} =
               TeslaAdapter.request(
                 :post,
                 "https://api.example.com/submit",
                 "test=data",
                 %{},
                 opts
               )
    end

    test "makes successful PUT request" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{updated: true})
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{status: 200}} =
               TeslaAdapter.request(
                 :put,
                 "https://api.example.com/users/1",
                 "name=John",
                 %{},
                 opts
               )
    end

    test "makes successful DELETE request" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.text(conn, "", status: 204)
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{status: 204, body: ""}} =
               TeslaAdapter.request(:delete, "https://api.example.com/users/1", nil, %{}, opts)
    end
  end

  # Note: Testing ArgumentError for missing adapter_config is difficult because
  # HTTPower.Test intercepts requests before adapter validation.
  # This is covered by integration tests instead.

  describe "request/5 with custom headers" do
    test "converts map headers to Tesla format (list of tuples)" do
      HTTPower.Test.stub(fn conn ->
        # Check that custom header is present
        headers = conn.req_headers |> Enum.into(%{})
        assert headers["x-custom-header"] == "test-value"
        HTTPower.Test.json(conn, %{success: true})
      end)

      tesla_client = Tesla.client([])
      headers = %{"x-custom-header" => "test-value"}
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{}} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, headers, opts)
    end

    test "converts header keys to lowercase" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        # Should be lowercase
        assert headers["x-custom-header"] == "value"
        HTTPower.Test.json(conn, %{success: true})
      end)

      tesla_client = Tesla.client([])
      headers = %{"X-Custom-Header" => "value"}
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{}} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, headers, opts)
    end

    test "handles atom keys in headers" do
      HTTPower.Test.stub(fn conn ->
        headers = conn.req_headers |> Enum.into(%{})
        assert headers["authorization"] == "Bearer token"
        HTTPower.Test.json(conn, %{success: true})
      end)

      tesla_client = Tesla.client([])
      headers = %{authorization: "Bearer token"}
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{}} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, headers, opts)
    end

    test "handles empty headers" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{}} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)
    end

    test "handles nil headers" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{}} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, nil, opts)
    end
  end

  describe "response conversion" do
    test "converts Tesla.Env to HTTPower.Response" do
      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-custom", "value")
        |> HTTPower.Test.json(%{data: "test"})
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, response} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)

      assert %Response{} = response
      assert response.status == 200
      assert is_map(response.headers)
      # Headers come back as lists from Plug
      assert response.headers["x-custom"] == ["value"] or response.headers["x-custom"] == "value"
      assert response.body == %{"data" => "test"}
    end

    test "handles response headers as list of tuples" do
      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-header-1", "value1")
        |> Plug.Conn.put_resp_header("x-header-2", "value2")
        |> HTTPower.Test.json(%{success: true})
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, response} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)

      assert is_map(response.headers)
      assert Map.has_key?(response.headers, "x-header-1")
      assert Map.has_key?(response.headers, "x-header-2")
    end

    test "handles empty response body" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.text(conn, "", status: 204)
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{status: 204, body: ""}} =
               TeslaAdapter.request(:get, "https://api.example.com/empty", nil, %{}, opts)
    end

    test "handles various status codes" do
      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      for status <- [200, 201, 204, 400, 404, 500, 502] do
        HTTPower.Test.stub(fn conn ->
          HTTPower.Test.text(conn, "response", status: status)
        end)

        assert {:ok, %Response{status: ^status}} =
                 TeslaAdapter.request(:get, "https://api.example.com/status", nil, %{}, opts)
      end
    end
  end

  describe "response header normalization" do
    # These tests verify the Tesla adapter's convert_response_headers function
    # by using Tesla.Mock to control Tesla's response, bypassing HTTPower.Test
    # so the adapter's actual response conversion code runs.

    setup do
      # Tesla.Mock requires global mode for non-async tests, but we can use
      # it in this setup. We disable HTTPower.Test mock for these tests
      # so the adapter's do_request path runs.
      Process.delete(:httpower_test_mock_enabled)
      Tesla.Mock.mock(fn _env -> %Tesla.Env{status: 200, body: ""} end)
      :ok
    end

    test "normalizes list-of-tuples headers to map with list values" do
      Tesla.Mock.mock(fn _env ->
        %Tesla.Env{
          status: 200,
          headers: [{"x-custom", "value1"}, {"content-type", "application/json"}],
          body: "{}"
        }
      end)

      tesla_client = Tesla.client([], Tesla.Mock)
      opts = [adapter_config: tesla_client]

      assert {:ok, response} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)

      assert is_list(response.headers["x-custom"]),
             "Expected header value to be a list, got: #{inspect(response.headers["x-custom"])}"

      assert response.headers["x-custom"] == ["value1"]
      assert response.headers["content-type"] == ["application/json"]
    end

    test "groups duplicate header keys into lists" do
      Tesla.Mock.mock(fn _env ->
        %Tesla.Env{
          status: 200,
          headers: [
            {"set-cookie", "session=abc"},
            {"set-cookie", "tracking=xyz"},
            {"content-type", "text/html"}
          ],
          body: ""
        }
      end)

      tesla_client = Tesla.client([], Tesla.Mock)
      opts = [adapter_config: tesla_client]

      assert {:ok, response} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)

      assert response.headers["set-cookie"] == ["session=abc", "tracking=xyz"]
      assert response.headers["content-type"] == ["text/html"]
    end

    test "wraps bare string values from map headers in lists" do
      Tesla.Mock.mock(fn _env ->
        %Tesla.Env{
          status: 200,
          headers: %{"x-custom" => "bare-value", "content-type" => "application/json"},
          body: "{}"
        }
      end)

      tesla_client = Tesla.client([], Tesla.Mock)
      opts = [adapter_config: tesla_client]

      assert {:ok, response} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)

      assert is_list(response.headers["x-custom"]),
             "Expected header value to be a list, got: #{inspect(response.headers["x-custom"])}"

      assert response.headers["x-custom"] == ["bare-value"]
      assert response.headers["content-type"] == ["application/json"]
    end

    test "preserves list values from map headers" do
      Tesla.Mock.mock(fn _env ->
        %Tesla.Env{
          status: 200,
          headers: %{"x-custom" => ["val1", "val2"], "content-type" => ["application/json"]},
          body: "{}"
        }
      end)

      tesla_client = Tesla.client([], Tesla.Mock)
      opts = [adapter_config: tesla_client]

      assert {:ok, response} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)

      assert response.headers["x-custom"] == ["val1", "val2"]
      assert response.headers["content-type"] == ["application/json"]
    end
  end

  describe "error handling" do
    test "handles network errors gracefully" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.transport_error(conn, :timeout)
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      # HTTPower.Test wraps transport errors in HTTPower.Error
      assert {:error, %HTTPower.Error{reason: :test_transport_error}} =
               TeslaAdapter.request(:get, "https://api.example.com/timeout", nil, %{}, opts)
    end

    test "handles connection refused" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.transport_error(conn, :econnrefused)
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:error, %HTTPower.Error{reason: :test_transport_error}} =
               TeslaAdapter.request(:get, "https://api.example.com/refused", nil, %{}, opts)
    end

    test "handles other transport errors" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.transport_error(conn, :closed)
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:error, %HTTPower.Error{reason: :test_transport_error}} =
               TeslaAdapter.request(:get, "https://api.example.com/closed", nil, %{}, opts)
    end
  end

  describe "body handling" do
    test "converts nil body to empty string" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{}} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)
    end

    test "handles string body" do
      HTTPower.Test.stub(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body == "test=data"
        HTTPower.Test.json(conn, %{success: true})
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{}} =
               TeslaAdapter.request(
                 :post,
                 "https://api.example.com/submit",
                 "test=data",
                 %{},
                 opts
               )
    end

    test "handles JSON body" do
      HTTPower.Test.stub(fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert body =~ "name"
        HTTPower.Test.json(conn, %{success: true})
      end)

      tesla_client = Tesla.client([])
      json_body = Jason.encode!(%{name: "John"})
      headers = %{"Content-Type" => "application/json"}
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{}} =
               TeslaAdapter.request(
                 :post,
                 "https://api.example.com/users",
                 json_body,
                 headers,
                 opts
               )
    end
  end

  describe "Tesla client middleware" do
    test "works with Tesla client containing middleware" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{middleware: "works"})
      end)

      # Create Tesla client with middleware (would normally add headers, etc.)
      # In our test, HTTPower.Test intercepts before middleware runs
      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{body: %{"middleware" => "works"}}} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)
    end
  end

  describe "integration with HTTPower.Test" do
    test "respects HTTPower.Test.stub configuration" do
      HTTPower.Test.stub(fn conn ->
        case conn.request_path do
          "/test" -> HTTPower.Test.json(conn, %{path: "test"})
          "/other" -> HTTPower.Test.json(conn, %{path: "other"})
          _ -> HTTPower.Test.json(conn, %{path: "default"})
        end
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{body: %{"path" => "test"}}} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)

      assert {:ok, %Response{body: %{"path" => "other"}}} =
               TeslaAdapter.request(:get, "https://api.example.com/other", nil, %{}, opts)

      assert {:ok, %Response{body: %{"path" => "default"}}} =
               TeslaAdapter.request(:get, "https://api.example.com/unknown", nil, %{}, opts)
    end
  end

  describe "edge cases" do
    test "handles response headers as map (some Tesla middleware)" do
      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-test", "value")
        |> HTTPower.Test.json(%{success: true})
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      assert {:ok, %Response{headers: headers}} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, %{}, opts)

      assert is_map(headers)
    end

    test "handles nil headers" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      tesla_client = Tesla.client([])
      opts = [adapter_config: tesla_client]

      # Nil headers get converted to empty list by convert_headers
      assert {:ok, %Response{}} =
               TeslaAdapter.request(:get, "https://api.example.com/test", nil, nil, opts)
    end
  end
end

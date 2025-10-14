defmodule HTTPower.Adapter.TeslaIntegrationTest do
  @moduledoc """
  Integration tests using Tesla adapter with HTTPower.Test.

  These tests use HTTPower.Test (adapter-agnostic) to prove that the Tesla adapter
  works identically to the Req adapter. This proves true adapter independence!
  """

  use ExUnit.Case, async: false
  import HTTPower.SharedTests

  setup_all do
    Application.put_env(:httpower, :test_mode, true)
    :ok
  end

  setup do
    HTTPower.Test.setup()

    HTTPower.Test.stub(fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/test"} ->
          HTTPower.Test.json(conn, %{status: "success", penguin: "🐧"})

        {"POST", "/submit"} ->
          HTTPower.Test.json(conn, %{received: "data"})

        {"POST", "/users"} ->
          HTTPower.Test.json(conn, %{created: true})

        {"PUT", "/users/1"} ->
          HTTPower.Test.json(conn, %{updated: true})

        {"DELETE", "/users/1"} ->
          HTTPower.Test.text(conn, "", status: 204)

        {"GET", "/users"} ->
          HTTPower.Test.json(conn, %{users: ["alice", "bob"]})

        {"GET", "/error"} ->
          HTTPower.Test.text(conn, "Internal Server Error", status: 500)

        _ ->
          HTTPower.Test.json(conn, %{default: true})
      end
    end)

    # Create a minimal Tesla client (not actually used since HTTPower.Test intercepts)
    tesla_client = Tesla.client([])

    # Return adapter options for Tesla
    {:ok, adapter_opts: [adapter: {HTTPower.Adapter.Tesla, tesla_client}]}
  end

  describe "Tesla adapter: basic HTTP methods" do
    test "get/2 works correctly", %{adapter_opts: adapter_opts} do
      test_basic_get(adapter_opts)
    end

    test "get/2 with custom headers and timeout", %{adapter_opts: adapter_opts} do
      test_get_with_headers_and_timeout(adapter_opts)
    end

    test "post/2 with body and headers", %{adapter_opts: adapter_opts} do
      test_post_with_body_and_headers(adapter_opts)
    end

    test "post/2 with custom content-type header", %{adapter_opts: adapter_opts} do
      test_post_with_custom_content_type(adapter_opts)
    end

    test "put/2 with body", %{adapter_opts: adapter_opts} do
      test_put_with_body(adapter_opts)
    end

    test "delete/2 method", %{adapter_opts: adapter_opts} do
      test_delete(adapter_opts)
    end
  end

  describe "Tesla adapter: test mode blocking" do
    test "blocks real requests when test_mode is true" do
      test_mode_blocks_real_requests(HTTPower.Adapter.Tesla)
    end
  end

  describe "Tesla adapter: retry logic" do
    test "respects max_retries configuration", %{adapter_opts: adapter_opts} do
      test_retry_respects_max_retries(adapter_opts)
    end
  end

  describe "Tesla adapter: configured clients" do
    test "works with HTTPower.new/1 client pattern", %{adapter_opts: adapter_opts} do
      test_configured_client(adapter_opts)
    end
  end
end

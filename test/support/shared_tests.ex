defmodule HTTPower.SharedTests do
  @moduledoc """
  Shared test helper functions that can be used across all adapter tests.

  This module contains test logic that should work identically regardless
  of the adapter being used (Req or Tesla). By sharing test helpers, we prove
  that HTTPower's features are truly adapter-agnostic.

  Each adapter test file can import these functions and call them with
  adapter-specific configuration.
  """

  import ExUnit.Assertions

  @doc """
  Tests basic GET request functionality.
  """
  def test_basic_get(adapter_opts) do
    assert {:ok, response} =
             HTTPower.get("https://api.example.com/test", adapter_opts)

    assert response.status == 200
    assert response.body == %{"status" => "success", "penguin" => "🐧"}
  end

  @doc """
  Tests GET request with custom headers and timeout.
  """
  def test_get_with_headers_and_timeout(adapter_opts) do
    assert {:ok, response} =
             HTTPower.get(
               "https://api.example.com/test",
               Keyword.merge(adapter_opts,
                 headers: %{"Authorization" => "Bearer test-token"},
                 timeout: 30
               )
             )

    assert response.status == 200
  end

  @doc """
  Tests POST request with body and headers.
  """
  def test_post_with_body_and_headers(adapter_opts) do
    {:ok, response} =
      HTTPower.post(
        "https://api.example.com/submit",
        Keyword.merge(adapter_opts,
          body: "test=data",
          headers: %{"Authorization" => "Bearer token"}
        )
      )

    assert response.status == 200
    assert response.body == %{"received" => "data"}
  end

  @doc """
  Tests POST request with custom content-type header.
  """
  def test_post_with_custom_content_type(adapter_opts) do
    {:ok, response} =
      HTTPower.post(
        "https://api.example.com/users",
        Keyword.merge(adapter_opts,
          body: ~s({"name": "John"}),
          headers: %{"Content-Type" => "application/json"}
        )
      )

    assert response.status == 200
  end

  @doc """
  Tests PUT request with body.
  """
  def test_put_with_body(adapter_opts) do
    {:ok, response} =
      HTTPower.put(
        "https://api.example.com/users/1",
        Keyword.merge(adapter_opts, body: "name=Jane")
      )

    assert response.status == 200
    assert response.body == %{"updated" => true}
  end

  @doc """
  Tests DELETE request.
  """
  def test_delete(adapter_opts) do
    {:ok, response} =
      HTTPower.delete("https://api.example.com/users/1", adapter_opts)

    assert response.status == 204
    assert response.body == ""
  end

  @doc """
  Tests that test mode blocks real (unmocked) requests.

  Note: This test temporarily disables HTTPower.Test mocking to verify
  that test_mode properly blocks unmocked requests.
  """
  def test_mode_blocks_real_requests(adapter_module) do
    Application.put_env(:httpower, :test_mode, true)
    assert HTTPower.test_mode?() == true

    # Temporarily disable HTTPower.Test mocking
    Process.delete(:httpower_test_mock_enabled)
    Process.delete(:httpower_test_stub)

    # Real request should be blocked (no adapter config = unmocked adapter)
    assert {:error, error} =
             HTTPower.get("https://api.example.com/real",
               adapter: adapter_module
             )

    assert error.reason == :network_blocked
    assert error.message == "Network access blocked in test mode"
  end

  @doc """
  Tests retry logic respects max_retries configuration.
  """
  def test_retry_respects_max_retries(adapter_opts) do
    # This endpoint returns 500 error
    assert {:ok, response} =
             HTTPower.get(
               "https://api.example.com/error",
               Keyword.merge(adapter_opts,
                 max_retries: 0,
                 base_delay: 1
               )
             )

    assert response.status == 500
  end

  @doc """
  Tests configured client with HTTPower.new/1.
  """
  def test_configured_client(adapter_opts) do
    httpower_client = HTTPower.new(adapter_opts)

    assert {:ok, response} =
             HTTPower.get(httpower_client, "https://api.example.com/users")

    assert response.status == 200
  end
end

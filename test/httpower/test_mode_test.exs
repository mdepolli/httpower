defmodule HTTPower.TestModeTest do
  # async: false — these tests toggle the global :httpower :test_mode flag and
  # mutate the shared :httpower_test_stubs ETS table, both of which would race
  # with other tests if run concurrently.
  use ExUnit.Case, async: false

  setup do
    HTTPower.Test.setup()

    # Save and restore the global test_mode flag around each test.
    original_config = Application.get_env(:httpower, :test_mode)

    on_exit(fn ->
      if original_config != nil do
        Application.put_env(:httpower, :test_mode, original_config)
      else
        Application.delete_env(:httpower, :test_mode)
      end
    end)

    :ok
  end

  describe "test mode blocking" do
    test "blocks real requests when test_mode is true" do
      Application.put_env(:httpower, :test_mode, true)

      assert HTTPower.test_mode?() == true

      # Temporarily disable HTTPower.Test mocking to test the blocking feature
      :ets.delete(:httpower_test_stubs, self())

      # Real request should be blocked
      assert {:error, error} = HTTPower.get("https://api.example.com/real")
      assert error.reason == :network_blocked
      assert error.message == "Network access blocked in test mode"

      # Re-enable mocking for subsequent tests
      :ets.insert(:httpower_test_stubs, {self(), nil})
    end

    test "allows requests with plug even in test mode" do
      Application.put_env(:httpower, :test_mode, true)

      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(200, "Test response")
      end)

      # Request with plug should work even in test mode
      assert {:ok, response} =
               HTTPower.get("https://api.example.com/test")

      assert response.body == "Test response"
    end

    test "allows real requests when test_mode is false" do
      Application.put_env(:httpower, :test_mode, false)

      assert HTTPower.test_mode?() == false

      # This would make a real request, but we'll stub it for this test
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{real: true})
      end)

      assert {:ok, response} =
               HTTPower.get("https://httpbin.org/json")

      assert response.status == 200
    end
  end

  describe "test_mode?/0" do
    test "reflects application config" do
      Application.put_env(:httpower, :test_mode, true)
      assert HTTPower.test_mode?() == true

      Application.put_env(:httpower, :test_mode, false)
      assert HTTPower.test_mode?() == false

      Application.delete_env(:httpower, :test_mode)
      assert HTTPower.test_mode?() == false
    end
  end
end

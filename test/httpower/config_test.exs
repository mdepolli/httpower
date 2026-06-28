defmodule HTTPower.ConfigTest do
  # async-safe despite Application.put_env/3: every key used below is unique to
  # the test that sets it (via System.unique_integer) and read by nothing else,
  # so concurrent tests can't observe them.
  use ExUnit.Case, async: true

  alias HTTPower.Config

  describe "resolve/2" do
    test "merges runtime app-env with the request opt, request opt winning" do
      key = :"resolve_merge_#{System.unique_integer([:positive])}"
      Application.put_env(:httpower, key, enabled: false, requests: 100)
      on_exit(fn -> Application.delete_env(:httpower, key) end)

      resolved = Config.resolve(key, [{key, [requests: 5]}])

      assert Keyword.get(resolved, :enabled) == false
      assert Keyword.get(resolved, :requests) == 5
    end

    test "reflects a runtime put_env on the next call (dynamic override)" do
      key = :"resolve_dynamic_#{System.unique_integer([:positive])}"
      on_exit(fn -> Application.delete_env(:httpower, key) end)

      assert Config.resolve(key, []) == []
      Application.put_env(:httpower, key, enabled: true)
      assert Keyword.get(Config.resolve(key, []), :enabled) == true
    end

    test "normalizes true/false/keyword/absent request opts" do
      key = :"resolve_norm_#{System.unique_integer([:positive])}"
      on_exit(fn -> Application.delete_env(:httpower, key) end)

      assert Config.resolve(key, [{key, true}]) == [enabled: true]
      assert Config.resolve(key, [{key, false}]) == [enabled: false]
      assert Config.resolve(key, [{key, [a: 1]}]) == [a: 1]
      assert Config.resolve(key, []) == []
      assert Config.resolve(key, [{key, "bogus"}]) == []
    end
  end
end

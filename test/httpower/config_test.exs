defmodule HTTPower.ConfigTest do
  # async-safe despite Application.put_env/3: the keys used below
  # (:test_config_key, :test_config_key2) are private to this test and read by
  # nothing else, so concurrent tests can't observe them.
  use ExUnit.Case, async: true

  alias HTTPower.Config

  describe "get/4" do
    test "returns request-level config when present" do
      assert Config.get([enabled: true], :enabled, :circuit_breaker, false) == true
    end

    test "falls back to application config when request config is nil" do
      Application.put_env(:httpower, :test_config_key, enabled: true)
      assert Config.get([], :enabled, :test_config_key, false) == true
      Application.delete_env(:httpower, :test_config_key)
    end

    test "falls back to default when neither request nor app config is set" do
      assert Config.get([], :enabled, :nonexistent_config_key, :my_default) == :my_default
    end

    test "request config takes precedence over application config" do
      Application.put_env(:httpower, :test_config_key2, enabled: true)
      assert Config.get([enabled: false], :enabled, :test_config_key2, true) == false
      Application.delete_env(:httpower, :test_config_key2)
    end
  end

  describe "enabled?/3" do
    test "checks if feature is enabled from request config" do
      assert Config.enabled?([enabled: true], :circuit_breaker, false) == true
      assert Config.enabled?([enabled: false], :circuit_breaker, true) == false
    end

    test "falls back to default when not configured" do
      assert Config.enabled?([], :nonexistent_feature, false) == false
      assert Config.enabled?([], :nonexistent_feature, true) == true
    end
  end

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

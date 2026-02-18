defmodule HTTPower.ConfigTest do
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
end

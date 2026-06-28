defmodule HTTPower.AdapterTest do
  use ExUnit.Case, async: true

  alias HTTPower.Adapter

  describe "normalize_response_headers/1" do
    test "wraps string values from a list of tuples into single-element lists" do
      headers = [{"content-type", "application/json"}, {"x-custom", "value"}]

      assert Adapter.normalize_response_headers(headers) == %{
               "content-type" => ["application/json"],
               "x-custom" => ["value"]
             }
    end

    test "groups duplicate keys from a tuple list into one list, preserving order" do
      headers = [{"set-cookie", "a=1"}, {"set-cookie", "b=2"}]

      assert Adapter.normalize_response_headers(headers) == %{"set-cookie" => ["a=1", "b=2"]}
    end

    test "wraps string values from a map into single-element lists" do
      headers = %{"content-type" => "application/json"}

      assert Adapter.normalize_response_headers(headers) == %{
               "content-type" => ["application/json"]
             }
    end

    test "preserves list values from a map" do
      headers = %{"set-cookie" => ["a=1", "b=2"]}

      assert Adapter.normalize_response_headers(headers) == %{"set-cookie" => ["a=1", "b=2"]}
    end

    test "stringifies non-binary keys" do
      headers = [{:"x-atom", "value"}]

      assert Adapter.normalize_response_headers(headers) == %{"x-atom" => ["value"]}
    end
  end
end

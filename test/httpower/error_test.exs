defmodule HTTPower.ErrorTest do
  use ExUnit.Case, async: true

  alias HTTPower.Error

  describe "struct" do
    test "creates error with reason and message" do
      error = %Error{reason: :timeout, message: "Request timeout"}
      assert error.reason == :timeout
      assert error.message == "Request timeout"
    end

    test "defaults to nil fields" do
      error = %Error{}
      assert error.reason == nil
      assert error.message == nil
    end
  end

  describe "message/1" do
    test "http_status tuple returns formatted status" do
      response = %HTTPower.Response{status: 500, headers: [], body: ""}
      assert Error.message({:http_status, 500, response}) == "HTTP 500 error"
    end

    test "http_status with different status codes" do
      response = %HTTPower.Response{status: 404, headers: [], body: ""}
      assert Error.message({:http_status, 404, response}) == "HTTP 404 error"

      response = %HTTPower.Response{status: 429, headers: [], body: ""}
      assert Error.message({:http_status, 429, response}) == "HTTP 429 error"
    end

    test "timeout" do
      assert Error.message(:timeout) == "Request timeout"
    end

    test "econnrefused" do
      assert Error.message(:econnrefused) == "Connection refused"
    end

    test "econnreset" do
      assert Error.message(:econnreset) == "Connection reset"
    end

    test "nxdomain" do
      assert Error.message(:nxdomain) == "Domain not found"
    end

    test "closed" do
      assert Error.message(:closed) == "Connection closed"
    end

    test "too_many_requests" do
      assert Error.message(:too_many_requests) == "Too many requests"
    end

    test "service_unavailable" do
      assert Error.message(:service_unavailable) == "Service unavailable"
    end

    test "dedup_timeout" do
      assert Error.message(:dedup_timeout) == "Request deduplication timeout"
    end

    test "catch-all with unknown atom inspects the reason" do
      assert Error.message(:some_unknown_error) == ":some_unknown_error"
    end

    test "catch-all with tuple inspects the reason" do
      assert Error.message({:feature_error, SomeModule, "details"}) ==
               "{:feature_error, SomeModule, \"details\"}"
    end

    test "catch-all with string inspects the reason" do
      assert Error.message("raw string error") == "\"raw string error\""
    end
  end

  describe "integration with struct construction" do
    test "message/1 is used to populate error structs" do
      reason = :timeout
      error = %Error{reason: reason, message: Error.message(reason)}
      assert error.reason == :timeout
      assert error.message == "Request timeout"
    end

    test "http_status error struct" do
      response = %HTTPower.Response{status: 502, headers: [], body: "bad gateway"}
      reason = {:http_status, 502, response}
      error = %Error{reason: reason, message: Error.message(reason)}
      assert error.reason == {:http_status, 502, response}
      assert error.message == "HTTP 502 error"
    end
  end
end

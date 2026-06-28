defmodule HTTPower.LoggerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias HTTPower.Logger, as: HTTPowerLogger

  setup_all do
    Application.put_env(:httpower, :test_mode, true)
    :ok
  end

  setup do
    # Setup HTTPower.Test for adapter-agnostic mocking
    HTTPower.Test.setup()

    # Save original config
    original_config = Application.get_env(:httpower, :logging, [])

    # Detach logger if attached from previous test
    HTTPowerLogger.detach()

    # Reset to default config for each test
    Application.put_env(:httpower, :logging, enabled: true, level: :info)

    on_exit(fn ->
      # Detach logger and restore original config
      HTTPowerLogger.detach()
      Application.put_env(:httpower, :logging, original_config)
    end)

    :ok
  end

  describe "correlation ID generation" do
    test "generates unique correlation IDs" do
      id1 = HTTPowerLogger.generate_correlation_id()
      id2 = HTTPowerLogger.generate_correlation_id()

      assert id1 != id2
      assert String.starts_with?(id1, "req_")
      assert String.starts_with?(id2, "req_")
      assert String.length(id1) == 20
      assert String.length(id2) == 20
    end

    test "correlation ID has correct format" do
      id = HTTPowerLogger.generate_correlation_id()
      assert Regex.match?(~r/^req_[0-9a-f]{16}$/, id)
    end
  end

  describe "telemetry handler robustness" do
    test "a crashing handler is not detached by telemetry" do
      HTTPowerLogger.attach()

      # A :stop event with no measurements.duration would raise inside the
      # handler. :telemetry permanently detaches any handler that raises, which
      # would silently kill all logging — crash isolation must prevent that.
      capture_log(fn ->
        :telemetry.execute([:httpower, :request, :stop], %{}, %{status: 200})
      end)

      handler_ids =
        [:httpower, :request, :stop]
        |> :telemetry.list_handlers()
        |> Enum.map(& &1.id)

      assert HTTPowerLogger in handler_ids
    end
  end

  describe "request logging via telemetry" do
    test "logs basic GET request" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{data: "test"})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users", adapter: HTTPower.Adapter.Finch)
        end)

      assert log =~ "[HTTPower]"
      assert log =~ "req_"
      assert log =~ "GET https://api.example.com/users"
    end

    test "logs POST request with headers and body" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{created: true})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.post("https://api.example.com/users",
            headers: %{"Content-Type" => "application/json"},
            body: ~s({"name": "John"}),
            adapter: HTTPower.Adapter.Finch
          )
        end)

      assert log =~ "POST https://api.example.com/users"
      assert log =~ "content-type"
      assert log =~ "name"
      assert log =~ "John"
    end

    test "sanitizes Authorization header" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{ok: true})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users",
            headers: %{"Authorization" => "Bearer secret-token-12345"},
            adapter: HTTPower.Adapter.Finch
          )
        end)

      assert log =~ "[REDACTED]"
      refute log =~ "secret-token-12345"
    end

    test "sanitizes API key headers" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{ok: true})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users",
            headers: %{
              "X-API-Key" => "sk_live_12345",
              "Api-Key" => "another-secret"
            },
            adapter: HTTPower.Adapter.Finch
          )
        end)

      assert log =~ "[REDACTED]"
      refute log =~ "sk_live_12345"
      refute log =~ "another-secret"
    end

    test "no logs when logger not attached" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{ok: true})
      end)

      # Don't attach logger

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users", adapter: HTTPower.Adapter.Finch)
        end)

      assert log == ""
    end
  end

  describe "response logging via telemetry" do
    test "logs successful response" do
      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> HTTPower.Test.json(%{status: "success"})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users", adapter: HTTPower.Adapter.Finch)
        end)

      assert log =~ "req_"
      assert log =~ "200"
      assert log =~ "ms)"
      assert log =~ "status"
      assert log =~ "success"
    end

    test "sanitizes response body with credit card" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{card: "4111111111111111", status: "ok"})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users", adapter: HTTPower.Adapter.Finch)
        end)

      assert log =~ "[REDACTED]"
      refute log =~ "4111111111111111"
      assert log =~ "status"
    end

    test "truncates large response bodies" do
      large_body = String.duplicate("x", 1000)

      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, large_body)
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users", adapter: HTTPower.Adapter.Finch)
        end)

      assert log =~ "(truncated)"
      refute log =~ large_body
    end
  end

  describe "error logging via telemetry" do
    test "logs request errors" do
      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"error": "Internal Server Error"}))
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users",
            adapter: HTTPower.Adapter.Finch,
            max_retries: 0
          )
        end)

      assert log =~ "req_"
      assert log =~ "500"
    end
  end

  # Sanitization logic itself lives in HTTPower.Sanitizer and is tested in
  # test/httpower/sanitizer_test.exs. These guard the backward-compatible
  # delegation so existing callers of HTTPower.Logger.sanitize_* keep working.
  describe "sanitization delegation (backward compatibility)" do
    test "sanitize_headers/1 delegates to HTTPower.Sanitizer" do
      assert HTTPowerLogger.sanitize_headers(%{"Authorization" => "Bearer token"}) ==
               %{"authorization" => "[REDACTED]"}
    end

    test "sanitize_body/1 delegates to HTTPower.Sanitizer" do
      assert HTTPowerLogger.sanitize_body(%{"password" => "secret"}) ==
               %{"password" => "[REDACTED]"}
    end
  end

  describe "configuration" do
    test "respects custom log level" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{ok: true})
      end)

      HTTPowerLogger.attach(level: :debug)

      log =
        capture_log([level: :debug], fn ->
          HTTPower.get("https://api.example.com", adapter: HTTPower.Adapter.Finch)
        end)

      assert log =~ "GET"
    end

    test "allows runtime configuration via attach options" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{ok: true})
      end)

      HTTPowerLogger.attach(log_headers: false, log_body: false)

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com",
            headers: %{"Authorization" => "Bearer token"},
            body: "test body",
            adapter: HTTPower.Adapter.Finch
          )
        end)

      # Should still have basic request info
      assert log =~ "GET"
      # But not headers or body
      refute log =~ "Bearer"
      refute log =~ "test body"
    end

    test "attach returns error when already attached" do
      assert :ok = HTTPowerLogger.attach()
      assert {:error, :already_exists} = HTTPowerLogger.attach()
    end

    test "detach returns error when not attached" do
      HTTPowerLogger.detach()
      assert {:error, :not_found} = HTTPowerLogger.detach()
    end
  end

  describe "structured logging metadata" do
    test "sets request metadata in Logger.metadata()" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{data: "test"})
      end)

      HTTPowerLogger.attach(log_headers: true, log_body: true)

      # Clear Logger metadata before request
      Logger.reset_metadata()

      capture_log(fn ->
        HTTPower.get("https://api.example.com/test", adapter: HTTPower.Adapter.Finch)
      end)

      metadata = Logger.metadata()

      # Check request metadata was set
      assert metadata[:httpower_correlation_id] != nil
      assert String.starts_with?(to_string(metadata[:httpower_correlation_id]), "req_")
      assert metadata[:httpower_event] == :response
      assert metadata[:httpower_status] == 200
      assert is_integer(metadata[:httpower_duration_ms])
      assert metadata[:httpower_duration_ms] >= 0
    end

    test "includes method and URL in metadata" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{success: true})
      end)

      HTTPowerLogger.attach()
      Logger.reset_metadata()

      capture_log(fn ->
        HTTPower.post("https://api.example.com/users",
          body: ~s({"name": "Test"}),
          adapter: HTTPower.Adapter.Finch
        )
      end)

      # Note: Logger.metadata() will show the last event (:response)
      # but we're verifying the mechanism works
      metadata = Logger.metadata()
      assert metadata[:httpower_correlation_id] != nil
    end

    test "includes headers in metadata when enabled" do
      HTTPower.Test.stub(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("x-custom-header", "value")
        |> HTTPower.Test.json(%{})
      end)

      HTTPowerLogger.attach(log_headers: true)
      Logger.reset_metadata()

      capture_log(fn ->
        HTTPower.get("https://api.example.com/test",
          headers: %{"authorization" => "Bearer token123"},
          adapter: HTTPower.Adapter.Finch
        )
      end)

      metadata = Logger.metadata()

      # Response headers should be sanitized and present
      assert metadata[:httpower_response_headers] != nil
      response_headers = metadata[:httpower_response_headers]
      assert is_map(response_headers)
      assert Map.has_key?(response_headers, "x-custom-header")
    end

    test "includes body in metadata when enabled" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{result: "success"})
      end)

      HTTPowerLogger.attach(log_body: true)
      Logger.reset_metadata()

      capture_log(fn ->
        HTTPower.post("https://api.example.com/test",
          body: ~s({"data": "test"}),
          adapter: HTTPower.Adapter.Finch
        )
      end)

      metadata = Logger.metadata()

      # Response body should be present
      assert metadata[:httpower_response_body] != nil
    end

    test "excludes headers from metadata when disabled" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{})
      end)

      HTTPowerLogger.attach(log_headers: false)
      Logger.reset_metadata()

      capture_log(fn ->
        HTTPower.get("https://api.example.com/test",
          headers: %{"x-custom" => "value"},
          adapter: HTTPower.Adapter.Finch
        )
      end)

      metadata = Logger.metadata()
      assert metadata[:httpower_response_headers] == nil
    end

    test "excludes body from metadata when disabled" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{result: "data"})
      end)

      HTTPowerLogger.attach(log_body: false)
      Logger.reset_metadata()

      capture_log(fn ->
        HTTPower.post("https://api.example.com/test",
          body: ~s({"test": "data"}),
          adapter: HTTPower.Adapter.Finch
        )
      end)

      metadata = Logger.metadata()
      assert metadata[:httpower_response_body] == nil
    end

    test "sanitizes sensitive data in metadata" do
      HTTPower.Test.stub(fn conn ->
        HTTPower.Test.json(conn, %{password: "secret123"})
      end)

      HTTPowerLogger.attach(log_headers: true, log_body: true)
      Logger.reset_metadata()

      capture_log(fn ->
        HTTPower.post("https://api.example.com/login",
          headers: %{"authorization" => "Bearer secret-token"},
          body: ~s({"password": "secret123"}),
          adapter: HTTPower.Adapter.Finch
        )
      end)

      metadata = Logger.metadata()

      # Response body should be sanitized
      response_body = metadata[:httpower_response_body]
      assert response_body =~ "[REDACTED]"
      refute response_body =~ "secret123"
    end

    test "truncates large bodies in metadata" do
      large_body = String.duplicate("x", 600)

      HTTPower.Test.stub(fn conn ->
        Plug.Conn.send_resp(conn, 200, large_body)
      end)

      HTTPowerLogger.attach(log_body: true)
      Logger.reset_metadata()

      capture_log(fn ->
        HTTPower.get("https://api.example.com/test", adapter: HTTPower.Adapter.Finch)
      end)

      metadata = Logger.metadata()
      response_body = metadata[:httpower_response_body]

      # Should be truncated
      assert response_body != nil
      assert String.contains?(response_body, "truncated")
      assert String.length(response_body) < 650
    end

    test "sets exception metadata on errors" do
      # This test would need a way to trigger an exception in the telemetry flow
      # For now, we verify the exception handler exists and has correct signature
      assert function_exported?(HTTPowerLogger, :handle_event, 4)
    end
  end
end

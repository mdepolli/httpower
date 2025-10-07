defmodule HTTPower.LoggerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias HTTPower.Logger, as: HTTPowerLogger

  setup_all do
    Application.put_env(:httpower, :test_mode, true)
    :ok
  end

  setup do
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

  describe "request logging via telemetry" do
    test "logs basic GET request" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{data: "test"})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users", plug: {Req.Test, HTTPower})
        end)

      assert log =~ "[HTTPower]"
      assert log =~ "req_"
      assert log =~ "GET https://api.example.com/users"
    end

    test "logs POST request with headers and body" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{created: true})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.post("https://api.example.com/users",
            headers: %{"Content-Type" => "application/json"},
            body: ~s({"name": "John"}),
            plug: {Req.Test, HTTPower}
          )
        end)

      assert log =~ "POST https://api.example.com/users"
      assert log =~ "content-type"
      assert log =~ "name"
      assert log =~ "John"
    end

    test "sanitizes Authorization header" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{ok: true})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users",
            headers: %{"Authorization" => "Bearer secret-token-12345"},
            plug: {Req.Test, HTTPower}
          )
        end)

      assert log =~ "[REDACTED]"
      refute log =~ "secret-token-12345"
    end

    test "sanitizes API key headers" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{ok: true})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users",
            headers: %{
              "X-API-Key" => "sk_live_12345",
              "Api-Key" => "another-secret"
            },
            plug: {Req.Test, HTTPower}
          )
        end)

      assert log =~ "[REDACTED]"
      refute log =~ "sk_live_12345"
      refute log =~ "another-secret"
    end

    test "no logs when logger not attached" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{ok: true})
      end)

      # Don't attach logger

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users", plug: {Req.Test, HTTPower})
        end)

      assert log == ""
    end
  end

  describe "response logging via telemetry" do
    test "logs successful response" do
      Req.Test.stub(HTTPower, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Req.Test.json(%{status: "success"})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users", plug: {Req.Test, HTTPower})
        end)

      assert log =~ "req_"
      assert log =~ "200"
      assert log =~ "ms)"
      assert log =~ "status"
      assert log =~ "success"
    end

    test "sanitizes response body with credit card" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{card: "4111111111111111", status: "ok"})
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users", plug: {Req.Test, HTTPower})
        end)

      assert log =~ "[REDACTED]"
      refute log =~ "4111111111111111"
      assert log =~ "status"
    end

    test "truncates large response bodies" do
      large_body = String.duplicate("x", 1000)

      Req.Test.stub(HTTPower, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, large_body)
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users", plug: {Req.Test, HTTPower})
        end)

      assert log =~ "(truncated)"
      refute log =~ large_body
    end

    test "no logs when logger not attached" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{ok: true})
      end)

      # Don't attach logger

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users", plug: {Req.Test, HTTPower})
        end)

      assert log == ""
    end
  end

  describe "error logging via telemetry" do
    test "logs request errors" do
      Req.Test.stub(HTTPower, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"error": "Internal Server Error"}))
      end)

      HTTPowerLogger.attach()

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users",
            plug: {Req.Test, HTTPower},
            max_retries: 0
          )
        end)

      assert log =~ "req_"
      assert log =~ "500"
    end

    test "no logs when logger not attached" do
      Req.Test.stub(HTTPower, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(500, ~s({"error": "Server Error"}))
      end)

      # Don't attach logger

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com/users",
            plug: {Req.Test, HTTPower},
            max_retries: 0
          )
        end)

      assert log == ""
    end
  end

  describe "header sanitization" do
    test "sanitizes default sensitive headers" do
      headers = %{
        "Authorization" => "Bearer token",
        "API-Key" => "secret",
        "X-API-Key" => "secret2",
        "Cookie" => "session=abc123",
        "Content-Type" => "application/json"
      }

      sanitized = HTTPowerLogger.sanitize_headers(headers)

      assert sanitized["authorization"] == "[REDACTED]"
      assert sanitized["api-key"] == "[REDACTED]"
      assert sanitized["x-api-key"] == "[REDACTED]"
      assert sanitized["cookie"] == "[REDACTED]"
      assert sanitized["content-type"] == "application/json"
    end

    test "sanitizes custom configured headers" do
      Application.put_env(:httpower, :logging,
        enabled: true,
        sanitize_headers: ["X-Custom-Secret"]
      )

      headers = %{
        "X-Custom-Secret" => "my-secret",
        "X-Normal-Header" => "value"
      }

      sanitized = HTTPowerLogger.sanitize_headers(headers)

      assert sanitized["x-custom-secret"] == "[REDACTED]"
      assert sanitized["x-normal-header"] == "value"
    end

    test "handles nil headers" do
      assert HTTPowerLogger.sanitize_headers(nil) == %{}
    end

    test "normalizes header keys to lowercase" do
      headers = %{
        "Authorization" => "Bearer token",
        "AUTHORIZATION" => "Bearer token2",
        "authorization" => "Bearer token3"
      }

      sanitized = HTTPowerLogger.sanitize_headers(headers)

      # All should be lowercased and redacted
      assert Map.keys(sanitized) |> Enum.all?(&(&1 == "authorization"))
      assert Map.values(sanitized) |> Enum.all?(&(&1 == "[REDACTED]"))
    end
  end

  describe "body sanitization - credit cards" do
    test "sanitizes credit card numbers in text" do
      body = "Card number: 4111111111111111"
      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4111111111111111"
    end

    test "sanitizes credit cards with spaces" do
      body = "Card: 4111 1111 1111 1111"
      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4111 1111 1111 1111"
    end

    test "sanitizes credit cards with dashes" do
      body = "Card: 4111-1111-1111-1111"
      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4111-1111-1111-1111"
    end

    test "sanitizes multiple credit cards" do
      body = "Card1: 4111111111111111, Card2: 5500000000000004"
      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4111111111111111"
      refute sanitized =~ "5500000000000004"
    end

    test "sanitizes AmEx cards (15 digits)" do
      body = "AmEx: 378282246310005"
      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "378282246310005"
    end
  end

  describe "body sanitization - CVV codes" do
    test "sanitizes CVV in text" do
      body = "cvv: 123"
      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized =~ "cvv: [REDACTED]"
    end

    test "sanitizes CVC in text" do
      body = "cvc: 456"
      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized =~ "cvc: [REDACTED]"
    end

    test "sanitizes CVV2 in text" do
      body = "cvv2: 789"
      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized =~ "cvv2: [REDACTED]"
    end
  end

  describe "body sanitization - JSON fields" do
    test "sanitizes password field in JSON string" do
      body = ~s({"username": "john", "password": "secret123"})
      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized =~ ~s("password": "[REDACTED]")
      refute sanitized =~ "secret123"
      assert sanitized =~ "john"
    end

    test "sanitizes multiple sensitive fields" do
      body = ~s({"password": "secret", "api_key": "key123", "name": "John"})
      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized =~ ~s("password": "[REDACTED]")
      assert sanitized =~ ~s("api_key": "[REDACTED]")
      refute sanitized =~ "secret"
      refute sanitized =~ "key123"
      assert sanitized =~ "John"
    end

    test "sanitizes credit_card field" do
      body = ~s({"credit_card": "4111111111111111", "amount": 100})
      sanitized = HTTPowerLogger.sanitize_body(body)

      # Should be sanitized by both field name and pattern matching
      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4111111111111111"
    end

    test "sanitizes custom configured fields" do
      Application.put_env(:httpower, :logging,
        enabled: true,
        sanitize_body_fields: ["custom_secret"]
      )

      body = ~s({"custom_secret": "value", "normal": "data"})
      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized =~ ~s("custom_secret": "[REDACTED]")
      assert sanitized =~ "normal"
    end
  end

  describe "body sanitization - maps" do
    test "sanitizes sensitive fields in maps" do
      body = %{
        "username" => "john",
        "password" => "secret123",
        "api_key" => "key456"
      }

      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized["username"] == "john"
      assert sanitized["password"] == "[REDACTED]"
      assert sanitized["api_key"] == "[REDACTED]"
    end

    test "sanitizes nested maps" do
      body = %{
        "user" => %{
          "name" => "John",
          "password" => "secret"
        },
        "auth" => %{
          "token" => "abc123"
        }
      }

      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized["user"]["name"] == "John"
      assert sanitized["user"]["password"] == "[REDACTED]"
      assert sanitized["auth"]["token"] == "[REDACTED]"
    end

    test "sanitizes maps with atom keys" do
      body = %{
        username: "john",
        password: "secret123"
      }

      sanitized = HTTPowerLogger.sanitize_body(body)

      assert sanitized[:username] == "john"
      assert sanitized[:password] == "[REDACTED]"
    end

    test "sanitizes lists of maps" do
      body = %{
        "users" => [
          %{"name" => "John", "password" => "secret1"},
          %{"name" => "Jane", "password" => "secret2"}
        ]
      }

      sanitized = HTTPowerLogger.sanitize_body(body)

      assert Enum.at(sanitized["users"], 0)["name"] == "John"
      assert Enum.at(sanitized["users"], 0)["password"] == "[REDACTED]"
      assert Enum.at(sanitized["users"], 1)["name"] == "Jane"
      assert Enum.at(sanitized["users"], 1)["password"] == "[REDACTED]"
    end
  end

  describe "body sanitization - edge cases" do
    test "handles nil body" do
      assert HTTPowerLogger.sanitize_body(nil) == nil
    end

    test "handles empty string" do
      assert HTTPowerLogger.sanitize_body("") == ""
    end

    test "handles empty map" do
      assert HTTPowerLogger.sanitize_body(%{}) == %{}
    end

    test "handles non-string, non-map body" do
      assert HTTPowerLogger.sanitize_body(123) == 123
      assert HTTPowerLogger.sanitize_body(:atom) == :atom
    end

    test "preserves non-sensitive data" do
      body = "This is normal text with no sensitive data"
      assert HTTPowerLogger.sanitize_body(body) == body
    end
  end

  describe "configuration" do
    test "respects custom log level" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{ok: true})
      end)

      HTTPowerLogger.attach(level: :debug)

      log =
        capture_log([level: :debug], fn ->
          HTTPower.get("https://api.example.com", plug: {Req.Test, HTTPower})
        end)

      assert log =~ "GET"
    end

    test "allows runtime configuration via attach options" do
      Req.Test.stub(HTTPower, fn conn ->
        Req.Test.json(conn, %{ok: true})
      end)

      HTTPowerLogger.attach(log_headers: false, log_body: false)

      log =
        capture_log(fn ->
          HTTPower.get("https://api.example.com",
            headers: %{"Authorization" => "Bearer token"},
            body: "test body",
            plug: {Req.Test, HTTPower}
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
end

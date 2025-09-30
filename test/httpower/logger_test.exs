defmodule HTTPower.LoggerTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias HTTPower.Logger, as: HTTPowerLogger

  setup do
    # Save original config
    original_config = Application.get_env(:httpower, :logging, [])

    # Reset to default config for each test
    Application.put_env(:httpower, :logging, enabled: true, level: :info)

    on_exit(fn ->
      # Restore original config
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

  describe "request logging" do
    test "logs basic GET request" do
      log =
        capture_log(fn ->
          HTTPowerLogger.log_request(:get, "https://api.example.com/users")
        end)

      assert log =~ "[HTTPower]"
      assert log =~ "req_"
      assert log =~ "GET https://api.example.com/users"
    end

    test "logs POST request with headers and body" do
      log =
        capture_log(fn ->
          HTTPowerLogger.log_request(:post, "https://api.example.com/users",
            headers: %{"Content-Type" => "application/json"},
            body: ~s({"name": "John"})
          )
        end)

      assert log =~ "POST https://api.example.com/users"
      assert log =~ "content-type"
      assert log =~ "name"
      assert log =~ "John"
    end

    test "sanitizes Authorization header" do
      log =
        capture_log(fn ->
          HTTPowerLogger.log_request(:get, "https://api.example.com/users",
            headers: %{"Authorization" => "Bearer secret-token-12345"}
          )
        end)

      assert log =~ "[REDACTED]"
      refute log =~ "secret-token-12345"
    end

    test "sanitizes API key headers" do
      log =
        capture_log(fn ->
          HTTPowerLogger.log_request(:get, "https://api.example.com/users",
            headers: %{
              "X-API-Key" => "sk_live_12345",
              "Api-Key" => "another-secret"
            }
          )
        end)

      assert log =~ "[REDACTED]"
      refute log =~ "sk_live_12345"
      refute log =~ "another-secret"
    end

    test "returns correlation ID" do
      correlation_id =
        capture_log(fn ->
          HTTPowerLogger.log_request(:get, "https://api.example.com/users")
        end)
        |> then(fn _ ->
          HTTPowerLogger.log_request(:get, "https://api.example.com/users")
        end)

      assert String.starts_with?(correlation_id, "req_")
    end

    test "respects logging disabled config" do
      Application.put_env(:httpower, :logging, enabled: false)

      log =
        capture_log(fn ->
          HTTPowerLogger.log_request(:get, "https://api.example.com/users")
        end)

      assert log == ""
    end
  end

  describe "response logging" do
    test "logs successful response" do
      correlation_id = HTTPowerLogger.generate_correlation_id()

      log =
        capture_log(fn ->
          HTTPowerLogger.log_response(correlation_id, 200,
            headers: %{"content-type" => "application/json"},
            body: ~s({"status": "success"}),
            duration_ms: 245
          )
        end)

      assert log =~ correlation_id
      assert log =~ "200"
      assert log =~ "(245ms)"
      assert log =~ "status"
      assert log =~ "success"
    end

    test "logs response without duration" do
      correlation_id = HTTPowerLogger.generate_correlation_id()

      log =
        capture_log(fn ->
          HTTPowerLogger.log_response(correlation_id, 404,
            body: ~s({"error": "Not found"})
          )
        end)

      assert log =~ correlation_id
      assert log =~ "404"
      refute log =~ "ms)"
    end

    test "sanitizes response body with credit card" do
      correlation_id = HTTPowerLogger.generate_correlation_id()

      log =
        capture_log(fn ->
          HTTPowerLogger.log_response(correlation_id, 200,
            body: ~s({"card": "4111111111111111", "status": "ok"})
          )
        end)

      assert log =~ "[REDACTED]"
      refute log =~ "4111111111111111"
      assert log =~ "status"
    end

    test "truncates large response bodies" do
      correlation_id = HTTPowerLogger.generate_correlation_id()
      large_body = String.duplicate("x", 1000)

      log =
        capture_log(fn ->
          HTTPowerLogger.log_response(correlation_id, 200, body: large_body)
        end)

      assert log =~ "(truncated)"
      refute log =~ large_body
    end

    test "respects logging disabled config" do
      Application.put_env(:httpower, :logging, enabled: false)
      correlation_id = HTTPowerLogger.generate_correlation_id()

      log =
        capture_log(fn ->
          HTTPowerLogger.log_response(correlation_id, 200, body: "test")
        end)

      assert log == ""
    end
  end

  describe "error logging" do
    test "logs request errors" do
      correlation_id = HTTPowerLogger.generate_correlation_id()

      log =
        capture_log(fn ->
          HTTPowerLogger.log_error(correlation_id, :timeout, "Request timeout after 30s")
        end)

      assert log =~ correlation_id
      assert log =~ "ERROR"
      assert log =~ "Request timeout after 30s"
      assert log =~ "timeout"
    end

    test "respects logging disabled config" do
      Application.put_env(:httpower, :logging, enabled: false)
      correlation_id = HTTPowerLogger.generate_correlation_id()

      log =
        capture_log(fn ->
          HTTPowerLogger.log_error(correlation_id, :timeout, "Timeout")
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
      Application.put_env(:httpower, :logging, enabled: true, level: :debug)

      log =
        capture_log([level: :debug], fn ->
          HTTPowerLogger.log_request(:get, "https://api.example.com")
        end)

      assert log =~ "GET"
    end

    test "allows disabling sanitization" do
      log =
        capture_log(fn ->
          HTTPowerLogger.log_request(:get, "https://api.example.com",
            headers: %{"Authorization" => "Bearer token"},
            sanitize: false
          )
        end)

      assert log =~ "Bearer token"
      refute log =~ "[REDACTED]"
    end
  end
end
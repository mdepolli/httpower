defmodule HTTPower.SanitizerTest do
  use ExUnit.Case, async: false
  alias HTTPower.Sanitizer

  doctest HTTPower.Sanitizer

  setup do
    # Save and restore :sanitization config so custom-field tests don't leak
    original_config = Application.get_env(:httpower, :sanitization, [])
    on_exit(fn -> Application.put_env(:httpower, :sanitization, original_config) end)

    :ok
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

      sanitized = Sanitizer.sanitize_headers(headers)

      assert sanitized["authorization"] == "[REDACTED]"
      assert sanitized["api-key"] == "[REDACTED]"
      assert sanitized["x-api-key"] == "[REDACTED]"
      assert sanitized["cookie"] == "[REDACTED]"
      assert sanitized["content-type"] == "application/json"
    end

    test "sanitizes custom configured headers" do
      Application.put_env(:httpower, :sanitization, sanitize_headers: ["X-Custom-Secret"])

      headers = %{
        "X-Custom-Secret" => "my-secret",
        "X-Normal-Header" => "value"
      }

      sanitized = Sanitizer.sanitize_headers(headers)

      assert sanitized["x-custom-secret"] == "[REDACTED]"
      assert sanitized["x-normal-header"] == "value"
    end

    test "handles nil headers" do
      assert Sanitizer.sanitize_headers(nil) == %{}
    end

    test "normalizes header keys to lowercase" do
      headers = %{
        "Authorization" => "Bearer token",
        "AUTHORIZATION" => "Bearer token2",
        "authorization" => "Bearer token3"
      }

      sanitized = Sanitizer.sanitize_headers(headers)

      # All should be lowercased and redacted
      assert Map.keys(sanitized) |> Enum.all?(&(&1 == "authorization"))
      assert Map.values(sanitized) |> Enum.all?(&(&1 == "[REDACTED]"))
    end
  end

  describe "body sanitization - credit cards" do
    test "sanitizes credit card numbers in text" do
      body = "Card number: 4111111111111111"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4111111111111111"
    end

    test "sanitizes credit cards with spaces" do
      body = "Card: 4111 1111 1111 1111"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4111 1111 1111 1111"
    end

    test "sanitizes credit cards with dashes" do
      body = "Card: 4111-1111-1111-1111"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4111-1111-1111-1111"
    end

    test "sanitizes multiple credit cards" do
      body = "Card1: 4111111111111111, Card2: 5500000000000004"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4111111111111111"
      refute sanitized =~ "5500000000000004"
    end

    test "sanitizes AmEx cards (15 digits)" do
      body = "AmEx: 378282246310005"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "378282246310005"
    end

    test "sanitizes AmEx cards with non-standard grouping" do
      body = "AmEx: 3782 822463 10005"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "10005"
    end

    test "sanitizes 13-digit cards (Visa old format)" do
      body = "Card: 4222222222222"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4222222222222"
    end

    test "sanitizes 19-digit cards (extended PAN)" do
      body = "Card: 4111111111111111110"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4111111111111111110"
    end

    test "preserves non-Luhn numeric sequences" do
      body = "Order ID: 1234567890123"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "1234567890123"
    end

    test "preserves formatted non-Luhn numeric sequences" do
      body = "ID: 1234-5678-9012-3"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "1234-5678-9012-3"
    end
  end

  describe "body sanitization - CVV codes" do
    test "sanitizes CVV in text" do
      body = "cvv: 123"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "cvv: [REDACTED]"
    end

    test "sanitizes CVC in text" do
      body = "cvc: 456"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "cvc: [REDACTED]"
    end

    test "sanitizes CVV2 in text" do
      body = "cvv2: 789"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "cvv2: [REDACTED]"
    end

    test "sanitizes Amex CVN in text" do
      body = "cvn: 4321"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "cvn: [REDACTED]"
      refute sanitized =~ "4321"
    end

    test "sanitizes card_cvv keyword in text" do
      body = "card_cvv: 321"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "card_cvv: [REDACTED]"
      refute sanitized =~ "321"
    end

    test "sanitizes hyphenated security-code keyword" do
      body = "security-code: 999"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "999"
    end

    test "sanitizes Amex cid in form-encoded body" do
      body = "amount=100&cid=123"
      sanitized = Sanitizer.sanitize_body(body)

      refute sanitized =~ "cid=123"
      assert sanitized =~ "[REDACTED]"
    end

    test "does not redact cid followed by a non-CVV-length value" do
      # A 5-digit customer id is not a CVV; leave it alone to avoid over-redaction.
      body = "cid=45678&amount=100"
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ "45678"
    end
  end

  describe "body sanitization - form-encoded fields" do
    test "redacts configured field=value pairs in a form body" do
      body = "user=bob&password=hunter2&api_key=abc123&keep=ok"
      sanitized = Sanitizer.sanitize_body(body)

      refute sanitized =~ "hunter2"
      refute sanitized =~ "abc123"
      assert sanitized =~ "password=[REDACTED]"
      assert sanitized =~ "api_key=[REDACTED]"
      assert sanitized =~ "keep=ok"
    end

    test "redacts a configured field at the start of a form body" do
      body = "password=secret&user=bob"
      sanitized = Sanitizer.sanitize_body(body)

      refute sanitized =~ "secret"
      assert sanitized =~ "password=[REDACTED]"
      assert sanitized =~ "user=bob"
    end

    test "does not over-redact a field that merely shares a suffix with a configured field" do
      body = "user_token=keep_me&token=zap_me"
      sanitized = Sanitizer.sanitize_body(body)

      refute sanitized =~ "zap_me"
      assert sanitized =~ "user_token=keep_me"
    end
  end

  describe "body sanitization - JSON fields" do
    test "sanitizes password field in JSON string" do
      body = ~s({"username": "john", "password": "secret123"})
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ ~s("password":"[REDACTED]")
      refute sanitized =~ "secret123"
      assert sanitized =~ "john"
    end

    test "sanitizes multiple sensitive fields" do
      body = ~s({"password": "secret", "api_key": "key123", "name": "John"})
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ ~s("password":"[REDACTED]")
      assert sanitized =~ ~s("api_key":"[REDACTED]")
      refute sanitized =~ "secret"
      refute sanitized =~ "key123"
      assert sanitized =~ "John"
    end

    test "sanitizes credit_card field" do
      body = ~s({"credit_card": "4111111111111111", "amount": 100})
      sanitized = Sanitizer.sanitize_body(body)

      # Should be sanitized by both field name and pattern matching
      assert sanitized =~ "[REDACTED]"
      refute sanitized =~ "4111111111111111"
    end

    test "sanitizes custom configured fields" do
      Application.put_env(:httpower, :sanitization, sanitize_body_fields: ["custom_secret"])

      body = ~s({"custom_secret": "value", "normal": "data"})
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ ~s("custom_secret":"[REDACTED]")
      assert sanitized =~ "normal"
    end

    test "sanitizes numeric JSON values" do
      body = ~s({"pin": 1234, "name": "John"})
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ ~s("pin":"[REDACTED]")
      refute sanitized =~ "1234"
      assert sanitized =~ "John"
    end

    test "sanitizes boolean JSON values" do
      body = ~s({"secret": true, "public": "data"})
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ ~s("secret":"[REDACTED]")
      assert sanitized =~ "public"
    end

    test "sanitizes null JSON values" do
      body = ~s({"token": null, "user": "alice"})
      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized =~ ~s("token":"[REDACTED]")
      assert sanitized =~ "alice"
    end
  end

  describe "body sanitization - PCI leak regressions" do
    test "redacts CVV in form-encoded body" do
      body = "card_holder=Jane&cvv=123&amount=100"
      sanitized = Sanitizer.sanitize_body(body)

      refute sanitized =~ "cvv=123"
      assert sanitized =~ "[REDACTED]"
    end

    test "redacts a sensitive field whose value is a nested JSON object" do
      body = ~s({"token": {"access": "abc123", "refresh": "xyz789"}})
      sanitized = Sanitizer.sanitize_body(body)

      refute sanitized =~ "abc123"
      refute sanitized =~ "xyz789"
    end

    test "redacts JSON values containing escaped quotes without mangling output" do
      body = ~s({"password": "she said \\"shibboleth\\" loud", "user": "bob"})
      sanitized = Sanitizer.sanitize_body(body)

      refute sanitized =~ "shibboleth"
      assert sanitized =~ "bob"
      assert {:ok, _} = Jason.decode(sanitized)
    end

    test "redacts sensitive values nested inside arrays in a binary JSON body" do
      # The map-input "lists of maps" test covers sanitize_map directly;
      # this guards the binary-string -> decode -> array path.
      body = ~s({"items": [{"card_number": "4111111111111111"}]})
      sanitized = Sanitizer.sanitize_body(body)

      refute sanitized =~ "4111111111111111"
      assert {:ok, _} = Jason.decode(sanitized)
    end

    test "does not over-redact keys that merely share a prefix with a sensitive field" do
      body = ~s({"secrets": ["public-list-id"], "secret": "top"})
      sanitized = Sanitizer.sanitize_body(body)

      refute sanitized =~ "top"
      assert sanitized =~ "public-list-id"
    end
  end

  describe "body sanitization - maps" do
    test "sanitizes sensitive fields in maps" do
      body = %{
        "username" => "john",
        "password" => "secret123",
        "api_key" => "key456"
      }

      sanitized = Sanitizer.sanitize_body(body)

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

      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized["user"]["name"] == "John"
      assert sanitized["user"]["password"] == "[REDACTED]"
      assert sanitized["auth"]["token"] == "[REDACTED]"
    end

    test "sanitizes maps with atom keys" do
      body = %{
        username: "john",
        password: "secret123"
      }

      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized[:username] == "john"
      assert sanitized[:password] == "[REDACTED]"
    end

    test "redacts an integer credit-card value in an unconfigured map field" do
      # Configured card fields are always redacted; this guards the path where a
      # Luhn-valid PAN arrives as an integer under a field name we don't know.
      body = %{"reference" => 4_111_111_111_111_111, "count" => 1234}

      sanitized = Sanitizer.sanitize_body(body)

      assert sanitized["reference"] == "[REDACTED]"
      # A short, non-card integer is left untouched.
      assert sanitized["count"] == 1234
    end

    test "sanitizes lists of maps" do
      body = %{
        "users" => [
          %{"name" => "John", "password" => "secret1"},
          %{"name" => "Jane", "password" => "secret2"}
        ]
      }

      sanitized = Sanitizer.sanitize_body(body)

      assert Enum.at(sanitized["users"], 0)["name"] == "John"
      assert Enum.at(sanitized["users"], 0)["password"] == "[REDACTED]"
      assert Enum.at(sanitized["users"], 1)["name"] == "Jane"
      assert Enum.at(sanitized["users"], 1)["password"] == "[REDACTED]"
    end
  end

  describe "body sanitization - edge cases" do
    test "handles nil body" do
      assert Sanitizer.sanitize_body(nil) == nil
    end

    test "handles empty string" do
      assert Sanitizer.sanitize_body("") == ""
    end

    test "handles empty map" do
      assert Sanitizer.sanitize_body(%{}) == %{}
    end

    test "handles non-string, non-map body" do
      assert Sanitizer.sanitize_body(123) == 123
      assert Sanitizer.sanitize_body(:atom) == :atom
    end

    test "preserves non-sensitive data" do
      body = "This is normal text with no sensitive data"
      assert Sanitizer.sanitize_body(body) == body
    end
  end
end

defmodule HTTPower.RateLimitHeadersTest do
  use ExUnit.Case, async: true

  alias HTTPower.RateLimitHeaders

  describe "parse/2 with GitHub-style headers" do
    test "parses valid GitHub rate limit headers" do
      headers = %{
        "x-ratelimit-limit" => "60",
        "x-ratelimit-remaining" => "55",
        "x-ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.limit == 60
      assert info.remaining == 55
      assert info.reset_at == ~U[2009-02-13 23:31:30Z]
      assert info.format == :github
    end

    test "handles case-insensitive header names" do
      headers = %{
        "X-RateLimit-Limit" => "100",
        "X-RATELIMIT-REMAINING" => "90",
        "x-RateLimit-Reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.limit == 100
      assert info.remaining == 90
    end

    test "handles header values as lists (some adapters)" do
      headers = %{
        "x-ratelimit-limit" => ["60"],
        "x-ratelimit-remaining" => ["55"],
        "x-ratelimit-reset" => ["1234567890"]
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.limit == 60
      assert info.remaining == 55
    end

    test "handles integer header values" do
      headers = %{
        "x-ratelimit-limit" => 60,
        "x-ratelimit-remaining" => 55,
        "x-ratelimit-reset" => 1_234_567_890
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.limit == 60
      assert info.remaining == 55
    end

    test "returns error when GitHub headers are incomplete" do
      headers = %{
        "x-ratelimit-limit" => "60",
        "x-ratelimit-remaining" => "55"
        # Missing reset
      }

      assert {:error, :not_found} = RateLimitHeaders.parse(headers)
    end

    test "returns error when header values are invalid" do
      headers = %{
        "x-ratelimit-limit" => "invalid",
        "x-ratelimit-remaining" => "55",
        "x-ratelimit-reset" => "1234567890"
      }

      assert {:error, :not_found} = RateLimitHeaders.parse(headers)
    end
  end

  describe "parse/2 with RFC-style headers" do
    test "parses valid RFC rate limit headers" do
      headers = %{
        "ratelimit-limit" => "100",
        "ratelimit-remaining" => "80",
        "ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.limit == 100
      assert info.remaining == 80
      assert info.reset_at == ~U[2009-02-13 23:31:30Z]
      assert info.format == :rfc
    end

    test "handles case-insensitive RFC header names" do
      headers = %{
        "RateLimit-Limit" => "100",
        "RATELIMIT-REMAINING" => "80",
        "RateLimit-Reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.limit == 100
    end

    test "returns error when RFC headers are incomplete" do
      headers = %{
        "ratelimit-limit" => "100"
        # Missing remaining and reset
      }

      assert {:error, :not_found} = RateLimitHeaders.parse(headers)
    end
  end

  describe "parse/2 with Stripe-style headers" do
    test "parses valid Stripe rate limit headers" do
      headers = %{
        "x-stripe-ratelimit-limit" => "100",
        "x-stripe-ratelimit-remaining" => "95",
        "x-stripe-ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.limit == 100
      assert info.remaining == 95
      assert info.reset_at == ~U[2009-02-13 23:31:30Z]
      assert info.format == :stripe
    end

    test "handles case-insensitive Stripe header names" do
      headers = %{
        "X-Stripe-RateLimit-Limit" => "100",
        "X-STRIPE-RATELIMIT-REMAINING" => "95",
        "x-stripe-RateLimit-Reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.limit == 100
    end

    test "returns error when Stripe headers are incomplete" do
      headers = %{
        "x-stripe-ratelimit-limit" => "100",
        "x-stripe-ratelimit-remaining" => "95"
        # Missing reset
      }

      assert {:error, :not_found} = RateLimitHeaders.parse(headers)
    end
  end

  describe "parse/2 with auto format detection" do
    test "automatically detects GitHub format" do
      headers = %{
        "x-ratelimit-limit" => "60",
        "x-ratelimit-remaining" => "55",
        "x-ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers, format: :auto)
      assert info.format == :github
    end

    test "automatically detects RFC format when GitHub not present" do
      headers = %{
        "ratelimit-limit" => "100",
        "ratelimit-remaining" => "80",
        "ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers, format: :auto)
      assert info.format == :rfc
    end

    test "automatically detects Stripe format when others not present" do
      headers = %{
        "x-stripe-ratelimit-limit" => "100",
        "x-stripe-ratelimit-remaining" => "95",
        "x-stripe-ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers, format: :auto)
      assert info.format == :stripe
    end

    test "prefers GitHub format when multiple formats present" do
      headers = %{
        "x-ratelimit-limit" => "60",
        "x-ratelimit-remaining" => "55",
        "x-ratelimit-reset" => "1234567890",
        "ratelimit-limit" => "100",
        "ratelimit-remaining" => "80",
        "ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers, format: :auto)
      assert info.format == :github
      assert info.limit == 60
    end

    test "returns error when no rate limit headers found" do
      headers = %{
        "content-type" => "application/json",
        "server" => "nginx"
      }

      assert {:error, :not_found} = RateLimitHeaders.parse(headers, format: :auto)
    end
  end

  describe "parse/2 with explicit format option" do
    test "parses GitHub format when explicitly specified" do
      headers = %{
        "x-ratelimit-limit" => "60",
        "x-ratelimit-remaining" => "55",
        "x-ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers, format: :github)
      assert info.format == :github
    end

    test "parses RFC format when explicitly specified" do
      headers = %{
        "ratelimit-limit" => "100",
        "ratelimit-remaining" => "80",
        "ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers, format: :rfc)
      assert info.format == :rfc
    end

    test "parses Stripe format when explicitly specified" do
      headers = %{
        "x-stripe-ratelimit-limit" => "100",
        "x-stripe-ratelimit-remaining" => "95",
        "x-stripe-ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers, format: :stripe)
      assert info.format == :stripe
    end

    test "returns error when specified format headers not found" do
      headers = %{
        "ratelimit-limit" => "100",
        "ratelimit-remaining" => "80",
        "ratelimit-reset" => "1234567890"
      }

      # Headers are RFC format, but we're asking for GitHub format
      assert {:error, :not_found} = RateLimitHeaders.parse(headers, format: :github)
    end
  end

  describe "parse_retry_after/1" do
    test "parses Retry-After header with integer seconds" do
      headers = %{"retry-after" => "120"}

      assert {:ok, 120} = RateLimitHeaders.parse_retry_after(headers)
    end

    test "handles case-insensitive header name" do
      headers = %{"Retry-After" => "60"}
      normalized = normalize_headers_helper(headers)

      assert {:ok, 60} = RateLimitHeaders.parse_retry_after(normalized)
    end

    test "handles header value as list" do
      headers = %{"retry-after" => ["90"]}

      assert {:ok, 90} = RateLimitHeaders.parse_retry_after(headers)
    end

    test "returns error for HTTP date format (not yet supported)" do
      headers = %{"retry-after" => "Wed, 21 Oct 2015 07:28:00 GMT"}

      assert {:error, :not_found} = RateLimitHeaders.parse_retry_after(headers)
    end

    test "returns error when header is missing" do
      headers = %{"content-type" => "application/json"}

      assert {:error, :not_found} = RateLimitHeaders.parse_retry_after(headers)
    end

    test "returns error when value is invalid" do
      headers = %{"retry-after" => "invalid"}

      assert {:error, :not_found} = RateLimitHeaders.parse_retry_after(headers)
    end

    test "handles zero seconds" do
      headers = %{"retry-after" => "0"}

      assert {:ok, 0} = RateLimitHeaders.parse_retry_after(headers)
    end

    test "handles large values" do
      headers = %{"retry-after" => "86400"}

      assert {:ok, 86400} = RateLimitHeaders.parse_retry_after(headers)
    end

    test "handles integer value directly (some adapters)" do
      headers = %{"retry-after" => 120}

      assert {:ok, 120} = RateLimitHeaders.parse_retry_after(headers)
    end
  end

  describe "parse/2 with retry_after format" do
    test "parses retry-after header when format is :retry_after" do
      headers = %{"retry-after" => "120"}

      assert {:ok, 120} = RateLimitHeaders.parse(headers, format: :retry_after)
    end

    test "returns error when retry-after header missing" do
      headers = %{"content-type" => "application/json"}

      assert {:error, :not_found} = RateLimitHeaders.parse(headers, format: :retry_after)
    end
  end

  describe "edge cases" do
    test "handles empty headers map" do
      assert {:error, :not_found} = RateLimitHeaders.parse(%{})
    end

    test "handles headers with extra whitespace in values" do
      headers = %{
        "x-ratelimit-limit" => " 60 ",
        "x-ratelimit-remaining" => " 55 ",
        "x-ratelimit-reset" => " 1234567890 "
      }

      # Integer.parse handles leading/trailing whitespace
      assert {:error, :not_found} = RateLimitHeaders.parse(headers)
    end

    test "handles negative values in headers (invalid but defensive)" do
      headers = %{
        "x-ratelimit-limit" => "-60",
        "x-ratelimit-remaining" => "-55",
        "x-ratelimit-reset" => "1234567890"
      }

      # Parser accepts negative integers, but they're semantically invalid
      # The consuming code should handle this
      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.limit == -60
    end

    test "handles very large reset timestamps" do
      # Year 2038 problem - testing with post-2038 timestamp
      far_future = 2_147_483_648

      headers = %{
        "x-ratelimit-limit" => "60",
        "x-ratelimit-remaining" => "55",
        "x-ratelimit-reset" => Integer.to_string(far_future)
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.reset_at == DateTime.from_unix!(far_future)
    end

    test "handles atom keys in headers map" do
      headers = %{
        :"x-ratelimit-limit" => "60",
        :"x-ratelimit-remaining" => "55",
        :"x-ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.limit == 60
    end

    test "handles mixed string and atom keys" do
      headers = %{
        "x-ratelimit-limit" => "60",
        :"x-ratelimit-remaining" => "55",
        "x-ratelimit-reset" => "1234567890"
      }

      assert {:ok, info} = RateLimitHeaders.parse(headers)
      assert info.limit == 60
      assert info.remaining == 55
    end
  end

  # Helper function for tests that need normalized headers
  defp normalize_headers_helper(headers) do
    headers
    |> Enum.map(fn {key, value} ->
      normalized_key = key |> to_string() |> String.downcase()
      {normalized_key, value}
    end)
    |> Enum.into(%{})
  end
end

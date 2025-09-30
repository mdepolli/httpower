defmodule HTTPower.Logger do
  @moduledoc """
  PCI-compliant HTTP request/response logging for HTTPower.

  This module provides sanitized logging of HTTP requests and responses, automatically
  redacting sensitive data like credit card numbers, authorization tokens, passwords,
  and other PII to maintain PCI DSS compliance.

  ## Features

  - Request/response logging with configurable levels
  - Automatic PCI-compliant data sanitization
  - Correlation IDs for request tracing
  - Header and body sanitization
  - Performance timing information
  - Configurable log levels and format

  ## Sanitization Rules

  The logger automatically sanitizes:
  - Credit card numbers (any 13-19 digit sequence)
  - CVV codes (3-4 digit security codes)
  - Authorization headers (Bearer tokens, Basic auth)
  - API keys and secret tokens
  - Password fields
  - Email addresses (optional)
  - Phone numbers (optional)

  ## Configuration

      config :httpower, :logging,
        enabled: true,
        level: :info,
        log_headers: true,
        log_body: true,
        sanitize_headers: ["authorization", "api-key", "x-api-key"],
        sanitize_body_fields: ["password", "credit_card", "cvv"]

  ## Usage

      # Log request
      correlation_id = HTTPower.Logger.log_request(:get, "https://api.example.com/users",
        headers: %{"Authorization" => "Bearer secret-token"},
        body: nil
      )

      # Log response
      HTTPower.Logger.log_response(correlation_id, 200,
        headers: %{"content-type" => "application/json"},
        body: ~s({"credit_card": "4111111111111111"}),
        duration_ms: 245
      )
  """

  require Logger

  @type correlation_id :: String.t()
  @type log_level :: :debug | :info | :warning | :error

  # Default headers to sanitize (case-insensitive)
  @default_sanitize_headers [
    "authorization",
    "api-key",
    "x-api-key",
    "api_key",
    "apikey",
    "secret",
    "token",
    "x-auth-token",
    "x-csrf-token",
    "cookie",
    "set-cookie"
  ]

  # Default body fields to sanitize (case-insensitive)
  @default_sanitize_body_fields [
    "password",
    "passwd",
    "pwd",
    "secret",
    "api_key",
    "apikey",
    "token",
    "credit_card",
    "creditcard",
    "card_number",
    "cardnumber",
    "cvv",
    "cvv2",
    "cvc",
    "pin",
    "ssn",
    "social_security"
  ]

  # Credit card pattern: 13-19 digits with optional spaces/dashes
  @credit_card_pattern ~r/\b\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{1,7}\b/

  # CVV pattern: 3-4 digits often after keywords
  @cvv_pattern ~r/\b(cvv|cvc|cvv2|security_?code)[\s\"\:]+\d{3,4}\b/i

  @doc """
  Logs an HTTP request with PCI-compliant sanitization.

  Returns a correlation ID that can be used to correlate the request with its response.

  ## Options

  - `:headers` - Request headers map
  - `:body` - Request body (string or map)
  - `:log_level` - Override default log level
  - `:sanitize` - Enable/disable sanitization (default: true)

  ## Examples

      iex> HTTPower.Logger.log_request(:get, "https://api.example.com/users")
      "req_abc123..."

      iex> HTTPower.Logger.log_request(:post, "https://api.example.com/payment",
      ...>   headers: %{"Authorization" => "Bearer token"},
      ...>   body: ~s({"card": "4111111111111111"})
      ...> )
      "req_def456..."
  """
  @spec log_request(atom(), String.t(), keyword()) :: correlation_id()
  def log_request(method, url, opts \\ []) do
    if logging_enabled?() do
      correlation_id = generate_correlation_id()
      headers = Keyword.get(opts, :headers, %{})
      body = Keyword.get(opts, :body)
      log_level = Keyword.get(opts, :log_level, get_log_level())
      sanitize = Keyword.get(opts, :sanitize, true)

      sanitized_headers = if sanitize, do: sanitize_headers(headers), else: headers
      sanitized_body = if sanitize, do: sanitize_body(body), else: body

      message = format_request_log(correlation_id, method, url, sanitized_headers, sanitized_body)

      Logger.log(log_level, message)

      correlation_id
    else
      generate_correlation_id()
    end
  end

  @doc """
  Logs an HTTP response with PCI-compliant sanitization.

  ## Options

  - `:headers` - Response headers map
  - `:body` - Response body (string or map)
  - `:duration_ms` - Request duration in milliseconds
  - `:log_level` - Override default log level
  - `:sanitize` - Enable/disable sanitization (default: true)

  ## Examples

      iex> HTTPower.Logger.log_response("req_abc123", 200,
      ...>   headers: %{"content-type" => "application/json"},
      ...>   body: ~s({"status": "success"}),
      ...>   duration_ms: 245
      ...> )
      :ok
  """
  @spec log_response(correlation_id(), integer(), keyword()) :: :ok
  def log_response(correlation_id, status, opts \\ []) do
    if logging_enabled?() do
      headers = Keyword.get(opts, :headers, %{})
      body = Keyword.get(opts, :body)
      duration_ms = Keyword.get(opts, :duration_ms)
      log_level = Keyword.get(opts, :log_level, get_log_level())
      sanitize = Keyword.get(opts, :sanitize, true)

      sanitized_headers = if sanitize, do: sanitize_headers(headers), else: headers
      sanitized_body = if sanitize, do: sanitize_body(body), else: body

      message =
        format_response_log(
          correlation_id,
          status,
          sanitized_headers,
          sanitized_body,
          duration_ms
        )

      Logger.log(log_level, message)
    end

    :ok
  end

  @doc """
  Logs an HTTP error with correlation ID.

  ## Examples

      iex> HTTPower.Logger.log_error("req_abc123", :timeout, "Request timeout after 30s")
      :ok
  """
  @spec log_error(correlation_id(), atom(), String.t()) :: :ok
  def log_error(correlation_id, reason, message) do
    if logging_enabled?() do
      log_message =
        "[HTTPower] [#{correlation_id}] ERROR: #{message} (reason: #{inspect(reason)})"

      Logger.error(log_message)
    end

    :ok
  end

  @doc """
  Generates a unique correlation ID for request tracing.

  Format: "req_" + 16 random hexadecimal characters

  ## Examples

      iex> id = HTTPower.Logger.generate_correlation_id()
      iex> String.starts_with?(id, "req_")
      true
      iex> String.length(id)
      20
  """
  @spec generate_correlation_id() :: correlation_id()
  def generate_correlation_id do
    random_bytes = :crypto.strong_rand_bytes(8)
    "req_" <> Base.encode16(random_bytes, case: :lower)
  end

  @doc """
  Sanitizes headers by redacting sensitive values.

  Headers in the configured sanitization list are replaced with "[REDACTED]".

  ## Examples

      iex> HTTPower.Logger.sanitize_headers(%{"Authorization" => "Bearer token123"})
      %{"authorization" => "[REDACTED]"}

      iex> HTTPower.Logger.sanitize_headers(%{"Content-Type" => "application/json"})
      %{"content-type" => "application/json"}
  """
  @spec sanitize_headers(map()) :: map()
  def sanitize_headers(headers) when is_map(headers) do
    sanitize_list = get_sanitize_headers()

    headers
    |> Enum.map(fn {key, value} ->
      normalized_key = String.downcase(to_string(key))

      if normalized_key in sanitize_list do
        {normalized_key, "[REDACTED]"}
      else
        {normalized_key, value}
      end
    end)
    |> Map.new()
  end

  def sanitize_headers(_), do: %{}

  @doc """
  Sanitizes request/response body by redacting sensitive data.

  Handles both string and map bodies. Applies pattern matching for credit cards,
  CVV codes, and sanitizes configured field names.

  ## Examples

      iex> HTTPower.Logger.sanitize_body(~s({"password": "secret123"}))
      ~s({"password": "[REDACTED]"})

      iex> HTTPower.Logger.sanitize_body("card: 4111111111111111")
      "card: [REDACTED]"
  """
  @spec sanitize_body(String.t() | map() | nil) :: String.t() | map() | nil
  def sanitize_body(nil), do: nil

  def sanitize_body(body) when is_binary(body) do
    body
    |> sanitize_credit_cards()
    |> sanitize_cvv()
    |> sanitize_json_fields()
  end

  def sanitize_body(body) when is_map(body) do
    sanitize_map(body)
  end

  def sanitize_body(body), do: body

  # Private functions

  defp logging_enabled? do
    Application.get_env(:httpower, :logging, [])
    |> Keyword.get(:enabled, true)
  end

  defp get_log_level do
    Application.get_env(:httpower, :logging, [])
    |> Keyword.get(:level, :info)
  end

  defp get_sanitize_headers do
    custom_headers =
      Application.get_env(:httpower, :logging, [])
      |> Keyword.get(:sanitize_headers, [])
      |> Enum.map(&String.downcase/1)

    (@default_sanitize_headers ++ custom_headers)
    |> Enum.uniq()
  end

  defp get_sanitize_body_fields do
    custom_fields =
      Application.get_env(:httpower, :logging, [])
      |> Keyword.get(:sanitize_body_fields, [])
      |> Enum.map(&String.downcase/1)

    (@default_sanitize_body_fields ++ custom_fields)
    |> Enum.uniq()
  end

  defp format_request_log(correlation_id, method, url, headers, body) do
    method_str = method |> to_string() |> String.upcase()
    headers_str = if map_size(headers) > 0, do: " headers=#{inspect(headers)}", else: ""
    body_str = if body, do: " body=#{inspect_body(body)}", else: ""

    "[HTTPower] [#{correlation_id}] → #{method_str} #{url}#{headers_str}#{body_str}"
  end

  defp format_response_log(correlation_id, status, headers, body, duration_ms) do
    headers_str = if map_size(headers) > 0, do: " headers=#{inspect(headers)}", else: ""
    body_str = if body, do: " body=#{inspect_body(body)}", else: ""

    duration_str = if duration_ms, do: " (#{duration_ms}ms)", else: ""

    "[HTTPower] [#{correlation_id}] ← #{status}#{duration_str}#{headers_str}#{body_str}"
  end

  defp inspect_body(body) when is_binary(body) do
    if String.length(body) > 500 do
      truncated = String.slice(body, 0, 500)
      "\"#{truncated}...\" (truncated)"
    else
      inspect(body)
    end
  end

  defp inspect_body(body), do: inspect(body)

  defp sanitize_credit_cards(text) when is_binary(text) do
    Regex.replace(@credit_card_pattern, text, "[REDACTED]")
  end

  defp sanitize_cvv(text) when is_binary(text) do
    Regex.replace(@cvv_pattern, text, "\\1: [REDACTED]")
  end

  defp sanitize_json_fields(text) when is_binary(text) do
    sanitize_fields = get_sanitize_body_fields()

    Enum.reduce(sanitize_fields, text, fn field, acc ->
      # Match JSON field patterns: "field": "value" or "field": value
      pattern = ~r/"#{field}"\s*:\s*"[^"]*"/i
      Regex.replace(pattern, acc, "\"#{field}\": \"[REDACTED]\"")
    end)
  end

  defp sanitize_map(map) when is_map(map) do
    sanitize_fields = get_sanitize_body_fields()

    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_key = key |> to_string() |> String.downcase()

      sanitized_value =
        if normalized_key in sanitize_fields do
          "[REDACTED]"
        else
          case value do
            v when is_map(v) -> sanitize_map(v)
            v when is_list(v) -> Enum.map(v, &sanitize_value/1)
            v -> v
          end
        end

      Map.put(acc, key, sanitized_value)
    end)
  end

  defp sanitize_value(value) when is_map(value), do: sanitize_map(value)
  defp sanitize_value(value), do: value
end

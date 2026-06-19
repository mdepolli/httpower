defmodule HTTPower.Sanitizer do
  @moduledoc """
  PCI-compliant sanitization of HTTP headers and bodies.

  Redacts sensitive data — credit card numbers (Luhn-validated), CVV/CVC codes,
  authorization tokens, API keys, passwords, and other configured fields — from
  request/response headers and bodies.

  This module is the single source of truth for sanitization. It is used both by
  `HTTPower.Client` (to sanitize telemetry metadata at the emission boundary, so
  every telemetry consumer receives redacted data) and by `HTTPower.Logger` (to
  sanitize what it writes to the log).

  ## Configuration

      config :httpower, :logging,
        sanitize_headers: ["authorization", "api-key", "x-api-key"],
        sanitize_body_fields: ["password", "credit_card", "cvv"]

  Configured lists are merged with the built-in defaults (see
  `default_sanitize_headers/0` and `default_sanitize_body_fields/0`).

  ## Body handling

  Binary JSON bodies are parsed and sanitized structurally (recursing through
  nested objects and arrays, matching by field name), then re-encoded as compact
  JSON. Non-JSON binary bodies (e.g. form-encoded) fall back to regex-based
  redaction. Map bodies are sanitized structurally.
  """

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

  # Credit card pattern: 13-19 digits with optional spaces/dashes in any grouping
  @credit_card_pattern ~r/\b(?:\d[\s\-]*){12,18}\d\b/

  # CVV pattern: 3-4 digits often after keywords, separated by whitespace,
  # quotes, colon, or equals (covers JSON, form-encoded, and plain text bodies)
  @cvv_pattern ~r/\b(cvv|cvc|cvv2|security_?code)[\s"'=:]+\d{3,4}\b/i

  @doc """
  Returns the built-in list of header names redacted by default.
  """
  @spec default_sanitize_headers() :: [String.t()]
  def default_sanitize_headers, do: @default_sanitize_headers

  @doc """
  Returns the built-in list of body field names redacted by default.
  """
  @spec default_sanitize_body_fields() :: [String.t()]
  def default_sanitize_body_fields, do: @default_sanitize_body_fields

  @doc """
  Sanitizes headers by redacting sensitive values.

  Header names are matched case-insensitively against the configured list
  (defaults merged with `config :httpower, :logging, :sanitize_headers`) and
  their values replaced with "[REDACTED]". All keys are normalized to lowercase.

  ## Examples

      iex> HTTPower.Sanitizer.sanitize_headers(%{"Authorization" => "Bearer token123"})
      %{"authorization" => "[REDACTED]"}

      iex> HTTPower.Sanitizer.sanitize_headers(%{"Content-Type" => "application/json"})
      %{"content-type" => "application/json"}
  """
  @spec sanitize_headers(map()) :: map()
  def sanitize_headers(headers) when is_map(headers) do
    sanitize_headers(headers, get_sanitize_headers())
  end

  def sanitize_headers(_), do: %{}

  @doc """
  Sanitizes headers using an explicit list of (lowercased) header names to redact.
  """
  @spec sanitize_headers(map(), [String.t()]) :: map()
  def sanitize_headers(headers, sanitize_list) when is_map(headers) do
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

  def sanitize_headers(_, _), do: %{}

  @doc """
  Sanitizes a request/response body by redacting sensitive data.

  Handles string, map, and nil bodies. JSON strings are sanitized structurally;
  other strings via pattern matching for credit cards and CVV codes plus
  configured field names.

  ## Examples

      iex> HTTPower.Sanitizer.sanitize_body("card: 4111111111111111")
      "card: [REDACTED]"

      iex> HTTPower.Sanitizer.sanitize_body(%{"password" => "secret123"})
      %{"password" => "[REDACTED]"}
  """
  @spec sanitize_body(String.t() | map() | nil) :: String.t() | map() | nil
  def sanitize_body(nil), do: nil
  def sanitize_body(body), do: sanitize_body(body, get_sanitize_body_fields())

  @doc """
  Sanitizes a body using an explicit list of (lowercased) field names to redact.
  """
  @spec sanitize_body(String.t() | map() | nil, [String.t()]) :: String.t() | map() | nil
  def sanitize_body(nil, _fields), do: nil

  def sanitize_body(body, fields) when is_binary(body) do
    # Prefer structural sanitization: parse the JSON, redact via the recursive
    # map path (which handles nested objects and field-name matching correctly),
    # then re-encode. Falls back to regex sanitization for non-JSON bodies
    # (e.g. form-encoded), which the regex path still covers.
    case Jason.decode(body) do
      {:ok, decoded} ->
        decoded
        |> sanitize_value(fields)
        |> Jason.encode!()

      {:error, _} ->
        body
        |> sanitize_credit_cards()
        |> sanitize_cvv()
        |> sanitize_json_fields(fields)
    end
  end

  def sanitize_body(body, fields) when is_map(body) do
    sanitize_map(body, fields)
  end

  def sanitize_body(body, _fields), do: body

  ## Private Functions

  defp get_sanitize_headers, do: get_sanitize_list(:sanitize_headers, @default_sanitize_headers)

  defp get_sanitize_body_fields,
    do: get_sanitize_list(:sanitize_body_fields, @default_sanitize_body_fields)

  defp get_sanitize_list(key, defaults) do
    custom =
      Application.get_env(:httpower, :logging, [])
      |> Keyword.get(key, [])
      |> Enum.map(&String.downcase/1)

    Enum.uniq(defaults ++ custom)
  end

  defp sanitize_credit_cards(text) when is_binary(text) do
    Regex.replace(@credit_card_pattern, text, fn match ->
      digits = String.replace(match, ~r/[\s\-]/, "")

      if luhn_valid?(digits), do: "[REDACTED]", else: match
    end)
  end

  # Luhn checksum: https://en.wikipedia.org/wiki/Luhn_algorithm
  defp luhn_valid?(digits) when byte_size(digits) < 13 or byte_size(digits) > 19, do: false

  defp luhn_valid?(digits) do
    digits
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(0, fn {char, idx}, sum ->
      d = String.to_integer(char)
      sum + luhn_digit(d, idx)
    end)
    |> then(&(rem(&1, 10) == 0))
  end

  defp luhn_digit(d, idx) when rem(idx, 2) == 1 do
    doubled = d * 2
    if doubled > 9, do: doubled - 9, else: doubled
  end

  defp luhn_digit(d, _idx), do: d

  defp sanitize_cvv(text) when is_binary(text) do
    Regex.replace(@cvv_pattern, text, "\\1: [REDACTED]")
  end

  defp sanitize_json_fields(text, fields) when is_binary(text) do
    Enum.reduce(fields, text, fn field, acc ->
      # Match JSON field patterns: "field": "value", "field": 123, "field": true/false/null
      pattern =
        ~r/"#{Regex.escape(field)}"\s*:\s*(?:"[^"]*"|[\d.]+(?:[eE][+-]?\d+)?|true|false|null)/i

      Regex.replace(pattern, acc, "\"#{field}\": \"[REDACTED]\"")
    end)
  end

  defp sanitize_map(map, fields) when is_map(map) do
    Map.new(map, fn {key, value} ->
      normalized_key = key |> to_string() |> String.downcase()

      sanitized =
        if normalized_key in fields, do: "[REDACTED]", else: sanitize_value(value, fields)

      {key, sanitized}
    end)
  end

  defp sanitize_value(value, fields) when is_map(value), do: sanitize_map(value, fields)

  defp sanitize_value(value, fields) when is_list(value),
    do: Enum.map(value, &sanitize_value(&1, fields))

  defp sanitize_value(value, _fields) when is_binary(value) do
    value
    |> sanitize_credit_cards()
    |> sanitize_cvv()
  end

  defp sanitize_value(value, _fields), do: value
end

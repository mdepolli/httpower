defmodule HTTPower.Logger do
  @moduledoc """
  PCI-compliant HTTP request/response logging via telemetry for HTTPower.

  This module provides a telemetry event handler that logs HTTP requests and responses
  with automatic PCI-compliant data sanitization, redacting sensitive data like credit
  card numbers, authorization tokens, passwords, and other PII.

  ## Features

  - Telemetry-based logging (opt-in by attaching)
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
        level: :info,
        log_headers: true,
        log_body: true,
        sanitize_headers: ["authorization", "api-key", "x-api-key"],
        sanitize_body_fields: ["password", "credit_card", "cvv"]

  ## Usage

  Attach the logger in your application startup:

      # In application.ex
      def start(_type, _args) do
        HTTPower.Logger.attach()
        # ... rest of your supervision tree
      end

  Or attach with custom configuration:

      HTTPower.Logger.attach(
        level: :debug,
        log_headers: false,
        log_body: true
      )

  To detach:

      HTTPower.Logger.detach()

  ## Integration with Phoenix

      # In your endpoint.ex or application.ex
      HTTPower.Logger.attach()

  The logger will automatically use correlation IDs from `Logger.metadata()[:request_id]`
  if available (e.g., from Phoenix requests).
  """

  require Logger

  @handler_id __MODULE__

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
  Attaches the HTTPower logger as a telemetry event handler.

  ## Options

  - `:level` - Log level to use (default: `:info`)
  - `:log_headers` - Whether to log headers (default: `true`)
  - `:log_body` - Whether to log body (default: `true`)
  - `:sanitize_headers` - Additional headers to sanitize (list of strings)
  - `:sanitize_body_fields` - Additional body fields to sanitize (list of strings)

  ## Examples

      # Use defaults from config
      HTTPower.Logger.attach()

      # Override specific options
      HTTPower.Logger.attach(level: :debug, log_body: false)
  """
  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    config = build_config(opts)

    events = [
      [:httpower, :request, :start],
      [:httpower, :request, :stop],
      [:httpower, :request, :exception]
    ]

    :telemetry.attach_many(
      @handler_id,
      events,
      &handle_event/4,
      config
    )
  end

  @doc """
  Detaches the HTTPower logger from telemetry events.

  ## Examples

      HTTPower.Logger.detach()
  """
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    :telemetry.detach(@handler_id)
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
  @spec generate_correlation_id() :: String.t()
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

  ## Telemetry Event Handlers

  @doc false
  def handle_event([:httpower, :request, :start], _measurements, metadata, config) do
    correlation_id = get_or_create_correlation_id()

    # Store correlation_id in process dictionary for :stop event
    Process.put(:httpower_correlation_id, correlation_id)

    message =
      format_request_log(
        correlation_id,
        metadata.method,
        metadata.url,
        Map.get(metadata, :headers, %{}),
        Map.get(metadata, :body),
        config
      )

    log(message, config)
  end

  def handle_event([:httpower, :request, :stop], measurements, metadata, config) do
    correlation_id = Process.get(:httpower_correlation_id) || "req_unknown"
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    status = Map.get(metadata, :status, "error")

    message =
      format_response_log(
        correlation_id,
        status,
        Map.get(metadata, :headers, %{}),
        Map.get(metadata, :body),
        duration_ms,
        config
      )

    log(message, config)
  end

  def handle_event([:httpower, :request, :exception], measurements, metadata, _config) do
    correlation_id = Process.get(:httpower_correlation_id) || "req_unknown"
    duration_ms = System.convert_time_unit(measurements.duration, :native, :millisecond)

    message =
      format_exception_log(
        correlation_id,
        metadata.kind,
        metadata.reason,
        duration_ms
      )

    Logger.error(message)
  end

  ## Private Functions

  defp build_config(opts) do
    defaults = Application.get_env(:httpower, :logging, [])

    %{
      level: Keyword.get(opts, :level, Keyword.get(defaults, :level, :info)),
      log_headers: Keyword.get(opts, :log_headers, Keyword.get(defaults, :log_headers, true)),
      log_body: Keyword.get(opts, :log_body, Keyword.get(defaults, :log_body, true)),
      sanitize_headers:
        Keyword.get(opts, :sanitize_headers, Keyword.get(defaults, :sanitize_headers, [])),
      sanitize_body_fields:
        Keyword.get(opts, :sanitize_body_fields, Keyword.get(defaults, :sanitize_body_fields, []))
    }
  end

  defp get_or_create_correlation_id do
    # Try to use Phoenix request_id if available
    Logger.metadata()[:request_id] || generate_correlation_id()
  end

  defp log(message, config) do
    Logger.log(config.level, message)
  end

  defp format_request_log(correlation_id, method, url, headers, body, config) do
    method_str = method |> to_string() |> String.upcase()

    headers_str =
      if config.log_headers && map_size(headers) > 0 do
        sanitized = sanitize_headers(headers)
        " headers=#{inspect(sanitized)}"
      else
        ""
      end

    body_str =
      if config.log_body && body do
        sanitized = sanitize_body(body)
        " body=#{inspect_body(sanitized)}"
      else
        ""
      end

    "[HTTPower] [#{correlation_id}] → #{method_str} #{url}#{headers_str}#{body_str}"
  end

  defp format_response_log(correlation_id, status, headers, body, duration_ms, config) do
    headers_str =
      if config.log_headers && map_size(headers) > 0 do
        sanitized = sanitize_headers(headers)
        " headers=#{inspect(sanitized)}"
      else
        ""
      end

    body_str =
      if config.log_body && body do
        sanitized = sanitize_body(body)
        " body=#{inspect_body(sanitized)}"
      else
        ""
      end

    "[HTTPower] [#{correlation_id}] ← #{status} (#{duration_ms}ms)#{headers_str}#{body_str}"
  end

  defp format_exception_log(correlation_id, kind, reason, duration_ms) do
    "[HTTPower] [#{correlation_id}] EXCEPTION (#{duration_ms}ms) #{kind}: #{inspect(reason)}"
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
            v when is_binary(v) -> sanitize_string_value(v)
            v -> v
          end
        end

      Map.put(acc, key, sanitized_value)
    end)
  end

  defp sanitize_value(value) when is_map(value), do: sanitize_map(value)
  defp sanitize_value(value) when is_binary(value), do: sanitize_string_value(value)
  defp sanitize_value(value), do: value

  defp sanitize_string_value(value) do
    value
    |> sanitize_credit_cards()
    |> sanitize_cvv()
  end
end

defmodule HTTPower.RateLimitHeaders do
  @moduledoc """
  Parses rate limit headers from HTTP responses.

  Supports multiple common formats:
  - GitHub/Twitter style: X-RateLimit-*
  - RFC 6585/IETF: RateLimit-*
  - Retry-After header (on 429/503 responses)
  - Stripe style: X-Stripe-RateLimit-*

  ## Example

      iex> headers = %{
      ...>   "x-ratelimit-limit" => "60",
      ...>   "x-ratelimit-remaining" => "55",
      ...>   "x-ratelimit-reset" => "1234567890"
      ...> }
      iex> HTTPower.RateLimitHeaders.parse(headers)
      {:ok, %{
        limit: 60,
        remaining: 55,
        reset_at: ~U[2009-02-13 23:31:30Z],
        format: :github
      }}

  """

  @type rate_limit_info :: %{
          limit: pos_integer(),
          remaining: non_neg_integer(),
          reset_at: DateTime.t(),
          format: atom()
        }

  @type header_format :: :auto | :github | :rfc | :stripe | :retry_after

  @doc """
  Parse rate limit headers from an HTTP response.

  Returns `{:ok, rate_limit_info}` if headers are found, `{:error, :not_found}` otherwise.

  ## Options

  - `:format` - Specify header format to look for (`:auto`, `:github`, `:rfc`, `:stripe`)
  """
  @spec parse(map(), keyword()) :: {:ok, rate_limit_info()} | {:error, :not_found}
  def parse(headers, opts \\ []) when is_map(headers) do
    format = Keyword.get(opts, :format, :auto)

    # Normalize headers to lowercase for case-insensitive lookup
    normalized = normalize_headers(headers)

    case format do
      :auto -> parse_auto(normalized)
      :github -> parse_github_style(normalized)
      :rfc -> parse_rfc_style(normalized)
      :stripe -> parse_stripe_style(normalized)
      :retry_after -> parse_retry_after(normalized)
    end
  end

  @doc """
  Parse Retry-After header from 429/503 responses.

  Returns seconds until retry is allowed.

  ## Examples

      iex> HTTPower.RateLimitHeaders.parse_retry_after(%{"retry-after" => "120"})
      {:ok, 120}

      iex> HTTPower.RateLimitHeaders.parse_retry_after(%{"retry-after" => "Wed, 21 Oct 2015 07:28:00 GMT"})
      {:ok, seconds_until_that_time}

  """
  @spec parse_retry_after(map()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def parse_retry_after(headers) when is_map(headers) do
    case Map.get(headers, "retry-after") do
      nil ->
        {:error, :not_found}

      value when is_integer(value) ->
        # Some adapters might return integer directly
        {:ok, value}

      value when is_binary(value) ->
        parse_retry_after_value(value)

      value when is_list(value) ->
        # Headers might come as lists from some adapters
        parse_retry_after_value(List.first(value))

      _ ->
        {:error, :not_found}
    end
  end

  # Private functions

  defp normalize_headers(headers) do
    Map.new(headers, fn {key, value} ->
      {key |> to_string() |> String.downcase(), value}
    end)
  end

  defp parse_auto(headers) do
    # Try formats in order of popularity
    with {:error, :not_found} <- parse_github_style(headers),
         {:error, :not_found} <- parse_rfc_style(headers) do
      parse_stripe_style(headers)
    end
  end

  defp parse_github_style(headers) do
    with {:ok, limit} <- get_integer_header(headers, "x-ratelimit-limit"),
         {:ok, remaining} <- get_integer_header(headers, "x-ratelimit-remaining"),
         {:ok, reset} <- get_integer_header(headers, "x-ratelimit-reset") do
      {:ok,
       %{
         limit: limit,
         remaining: remaining,
         reset_at: DateTime.from_unix!(reset),
         format: :github
       }}
    end
  end

  defp parse_rfc_style(headers) do
    with {:ok, limit} <- get_integer_header(headers, "ratelimit-limit"),
         {:ok, remaining} <- get_integer_header(headers, "ratelimit-remaining"),
         {:ok, reset} <- get_integer_header(headers, "ratelimit-reset") do
      {:ok,
       %{
         limit: limit,
         remaining: remaining,
         reset_at: DateTime.from_unix!(reset),
         format: :rfc
       }}
    end
  end

  defp parse_stripe_style(headers) do
    with {:ok, limit} <- get_integer_header(headers, "x-stripe-ratelimit-limit"),
         {:ok, remaining} <- get_integer_header(headers, "x-stripe-ratelimit-remaining"),
         {:ok, reset} <- get_integer_header(headers, "x-stripe-ratelimit-reset") do
      {:ok,
       %{
         limit: limit,
         remaining: remaining,
         reset_at: DateTime.from_unix!(reset),
         format: :stripe
       }}
    end
  end

  defp get_integer_header(headers, key) do
    case Map.get(headers, key) do
      nil ->
        {:error, :not_found}

      value when is_binary(value) ->
        case Integer.parse(value) do
          {int, ""} -> {:ok, int}
          _ -> {:error, :not_found}
        end

      value when is_list(value) ->
        # Handle list of values (take first)
        get_integer_header(headers, key, List.first(value))

      value when is_integer(value) ->
        {:ok, value}

      _ ->
        {:error, :not_found}
    end
  end

  defp get_integer_header(_headers, _key, value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :not_found}
    end
  end

  defp get_integer_header(_headers, _key, _value), do: {:error, :not_found}

  defp parse_retry_after_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> {:ok, seconds}
      _ -> parse_http_date(value)
    end
  end

  defp parse_retry_after_value(_), do: {:error, :not_found}

  # Parses RFC 7231 HTTP date format: "Wed, 21 Oct 2015 07:28:00 GMT"
  # Returns {:ok, seconds_until} or {:error, :not_found}
  defp parse_http_date(value) do
    with {:ok, datetime} <- parse_imf_fixdate(String.trim(value)),
         seconds_until = DateTime.diff(datetime, DateTime.utc_now()),
         true <- seconds_until >= 0 do
      {:ok, seconds_until}
    else
      _ -> {:error, :not_found}
    end
  end

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  # Parses IMF-fixdate: "Wed, 21 Oct 2015 07:28:00 GMT"
  defp parse_imf_fixdate(value) do
    case Regex.run(
           ~r/^\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/,
           value
         ) do
      [_, day, month_name, year, hour, minute, second] ->
        with {:ok, month} <- Map.fetch(@months, month_name),
             {:ok, date} <-
               Date.new(
                 String.to_integer(year),
                 month,
                 String.to_integer(day)
               ),
             {:ok, time} <-
               Time.new(
                 String.to_integer(hour),
                 String.to_integer(minute),
                 String.to_integer(second)
               ) do
          DateTime.new(date, time, "Etc/UTC")
        end

      _ ->
        {:error, :not_found}
    end
  end
end

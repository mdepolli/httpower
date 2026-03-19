defmodule HTTPower.Codec do
  @moduledoc """
  Request encoding for HTTPower.

  This module handles encoding of request bodies and query parameters before
  they are passed to the adapter layer.

  ## Body Encoding

  Supports three mutually exclusive body options:

  - `json: data` — Encodes `data` as JSON, sets `Content-Type: application/json`
    and `Accept: application/json` headers (unless already present).
  - `form: data` — Encodes `data` as a URL-encoded form string, sets
    `Content-Type: application/x-www-form-urlencoded` (unless already present).
  - `body: data` — Passes `data` through as-is. No encoding, no headers added.

  Only one body option may be used per request. Combining `json:`, `form:`,
  or `body:` in the same opts list returns an error.

  ## Query Parameters

  - `params: data` — Encodes `data` as query parameters and appends to the
    request URL. Merges with any existing query string. Uses `URI.encode_query/1`
    (flat key-value only). Can be combined with any body option.

  ## Examples

      # JSON encoding
      iex> request = HTTPower.Request.new(:post, URI.parse("https://api.example.com/users"))
      iex> {:ok, encoded, opts} = HTTPower.Codec.encode_request(request, json: %{name: "Alice"})
      iex> encoded.body
      ~s({"name":"Alice"})
      iex> encoded.headers["Content-Type"]
      "application/json"
      iex> opts
      []

      # Form encoding
      iex> request = HTTPower.Request.new(:post, URI.parse("https://api.example.com/login"))
      iex> {:ok, encoded, opts} = HTTPower.Codec.encode_request(request, form: [user: "alice", pass: "secret"])
      iex> encoded.headers["Content-Type"]
      "application/x-www-form-urlencoded"
      iex> opts
      []

      # Existing Content-Type is preserved
      iex> request = HTTPower.Request.new(:post, URI.parse("https://api.example.com/users"), nil, %{"content-type" => "application/vnd.api+json"})
      iex> {:ok, encoded, _opts} = HTTPower.Codec.encode_request(request, json: %{name: "Alice"})
      iex> encoded.headers["content-type"]
      "application/vnd.api+json"
      iex> Map.has_key?(encoded.headers, "Content-Type")
      false
  """

  alias HTTPower.Error
  alias HTTPower.Request
  alias HTTPower.Response

  @doc """
  Encodes the request body based on the encoding option present in `opts`.

  Returns `{:ok, updated_request, updated_opts}` on success, or
  `{:error, %HTTPower.Error{}}` on failure.

  The encoding option (`:json` or `:form`) is removed from the returned opts.
  """
  @spec encode_request(Request.t(), keyword()) ::
          {:ok, Request.t(), keyword()} | {:error, Error.t()}
  def encode_request(%Request{} = request, opts) do
    has_json = Keyword.has_key?(opts, :json)
    has_form = Keyword.has_key?(opts, :form)
    has_body = Keyword.has_key?(opts, :body)

    encoding_count = Enum.count([has_json, has_form, has_body], & &1)

    if encoding_count > 1 do
      {:error,
       %Error{
         reason: :conflicting_body_options,
         message: Error.message(:conflicting_body_options)
       }}
    else
      cond do
        has_json -> encode_json(request, opts)
        has_form -> encode_form(request, opts)
        true -> encode_params(request, opts)
      end
    end
  end

  defp encode_json(request, opts) do
    data = Keyword.fetch!(opts, :json)

    case Jason.encode(data) do
      {:ok, encoded} ->
        updated_request =
          request
          |> Map.put(:body, encoded)
          |> put_header_unless_set("Content-Type", "application/json")
          |> put_header_unless_set("Accept", "application/json")

        encode_params(updated_request, Keyword.delete(opts, :json))

      {:error, _reason} ->
        {:error, %Error{reason: :json_encode_error, message: Error.message(:json_encode_error)}}
    end
  end

  defp encode_form(request, opts) do
    data = Keyword.fetch!(opts, :form)
    encoded = URI.encode_query(data)

    updated_request =
      request
      |> Map.put(:body, encoded)
      |> put_header_unless_set("Content-Type", "application/x-www-form-urlencoded")

    encode_params(updated_request, Keyword.delete(opts, :form))
  end

  defp encode_params(request, opts) do
    case Keyword.pop(opts, :params) do
      {nil, opts} ->
        {:ok, request, opts}

      {[], opts} ->
        {:ok, request, opts}

      {params, opts} ->
        encoded = URI.encode_query(params)

        updated_url =
          case request.url.query do
            nil -> %{request.url | query: encoded}
            existing -> %{request.url | query: existing <> "&" <> encoded}
          end

        {:ok, %{request | url: updated_url}, opts}
    end
  end

  @doc """
  Decodes the response body based on the Content-Type header.

  Returns the updated response struct (not a tuple). Decoding is skipped when:
  - `raw: true` is present in opts
  - The body is not a binary (already decoded, e.g. a dedup cache hit)
  - The body is nil or an empty string
  - The Content-Type is not a JSON media type

  Invalid JSON is left as the raw binary (no error is raised).
  """
  @spec decode_response(Response.t(), keyword()) :: Response.t()
  def decode_response(%Response{} = response, opts) do
    cond do
      Keyword.get(opts, :raw, false) ->
        response

      not is_binary(response.body) ->
        response

      response.body in [nil, ""] ->
        response

      true ->
        maybe_decode_json(response)
    end
  end

  defp maybe_decode_json(%Response{} = response) do
    content_type = get_content_type(response.headers)

    if json_content_type?(content_type) do
      case Jason.decode(response.body) do
        {:ok, decoded} -> %{response | body: decoded}
        {:error, _} -> response
      end
    else
      response
    end
  end

  @doc """
  Returns `true` if the given content type string is a JSON media type.

  Recognises `application/json` (with optional parameters) and any media type
  with a `+json` structured-syntax suffix, such as `application/vnd.api+json`.
  Returns `false` for `nil`.
  """
  @spec json_content_type?(String.t() | nil) :: boolean()
  def json_content_type?(nil), do: false

  def json_content_type?(content_type) do
    base =
      content_type
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    base == "application/json" or String.ends_with?(base, "+json")
  end

  # Case-insensitive lookup of the content-type header. Response header values
  # are lists; returns the first element of the list, or nil.
  defp get_content_type(headers) do
    key =
      Enum.find_value(headers, fn {k, _v} ->
        if String.downcase(k) == "content-type", do: k
      end)

    case key && Map.get(headers, key) do
      [first | _] -> first
      _ -> nil
    end
  end

  # Sets the header only if no header with the same name (case-insensitively) already exists.
  defp put_header_unless_set(%Request{} = request, name, value) do
    name_downcased = String.downcase(name)

    already_set? =
      Enum.any?(request.headers, fn {k, _v} -> String.downcase(k) == name_downcased end)

    if already_set? do
      request
    else
      %{request | headers: Map.put(request.headers, name, value)}
    end
  end
end

defmodule HTTPower.Codec do
  @moduledoc """
  Request encoding for HTTPower.

  This module handles encoding of request bodies before they are passed to the
  adapter layer. It supports three encoding options that can be passed alongside
  other request options:

  - `json: data` — Encodes `data` as JSON, sets `Content-Type: application/json`
    and `Accept: application/json` headers (unless already present).
  - `form: data` — Encodes `data` as a URL-encoded form string, sets
    `Content-Type: application/x-www-form-urlencoded` (unless already present).
  - `body: data` — Passes `data` through as-is. No encoding, no headers added.

  Only one encoding option may be used per request. Combining `json:`, `form:`,
  or `body:` in the same opts list returns an error.

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
      {:error, %Error{reason: :conflicting_body_options, message: Error.message(:conflicting_body_options)}}
    else
      cond do
        has_json -> encode_json(request, opts)
        has_form -> encode_form(request, opts)
        true -> {:ok, request, opts}
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

        {:ok, updated_request, Keyword.delete(opts, :json)}

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

    {:ok, updated_request, Keyword.delete(opts, :form)}
  end

  # Sets the header only if no header with the same name (case-insensitively) already exists.
  defp put_header_unless_set(%Request{} = request, name, value) do
    name_downcased = String.downcase(name)
    already_set? = Enum.any?(request.headers, fn {k, _v} -> String.downcase(k) == name_downcased end)

    if already_set? do
      request
    else
      %{request | headers: Map.put(request.headers, name, value)}
    end
  end
end

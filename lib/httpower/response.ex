defmodule HTTPower.Response do
  @moduledoc """
  HTTP response struct from HTTPower.

  This struct completely abstracts away the underlying HTTP library
  and provides a clean, consistent interface.

  ## Body Decoding

  Response bodies with a JSON Content-Type (`application/json` or `+json` suffix)
  are automatically decoded into Elixir data structures. All other content types
  return the raw binary body. Use `raw: true` in request options to skip decoding.
  """

  defstruct [
    :status,
    :headers,
    :body
  ]

  @type t :: %__MODULE__{
          status: integer(),
          headers: %{optional(String.t()) => [String.t()]},
          body: term()
        }
end

defmodule HTTPower.Response do
  @moduledoc """
  HTTP response struct from HTTPower.

  This struct completely abstracts away the underlying HTTP library
  and provides a clean, consistent interface.
  """

  defstruct [
    :status,
    :headers,
    :body
  ]

  @type t :: %__MODULE__{
          status: integer(),
          headers: map(),
          body: String.t()
        }
end

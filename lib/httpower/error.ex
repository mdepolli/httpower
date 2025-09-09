defmodule HTTPower.Error do
  @moduledoc """
  HTTP error struct from HTTPower.

  This struct provides a clean abstraction for all possible HTTP errors,
  whether they're network issues, timeouts, or other problems.
  """

  defstruct [
    :reason,
    :message
  ]

  @type t :: %__MODULE__{
          reason: atom(),
          message: String.t()
        }
end

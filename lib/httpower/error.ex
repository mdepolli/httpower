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

  @doc false
  def message({:http_status, status, _response}), do: "HTTP #{status} error"
  def message(:timeout), do: "Request timeout"
  def message(:econnrefused), do: "Connection refused"
  def message(:econnreset), do: "Connection reset"
  def message(:nxdomain), do: "Domain not found"
  def message(:closed), do: "Connection closed"
  def message(:too_many_requests), do: "Too many requests"
  def message(:service_unavailable), do: "Service unavailable"
  def message(:dedup_timeout), do: "Request deduplication timeout"
  def message(reason), do: inspect(reason)
end

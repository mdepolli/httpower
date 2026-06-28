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

  @type reason ::
          atom()
          | {:http_status, integer(), HTTPower.Response.t()}
          | {:feature_error, module(), term()}

  @type t :: %__MODULE__{
          reason: reason(),
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

  def message(:conflicting_body_options),
    do: "Cannot use multiple body options (json:, form:, body:) simultaneously"

  def message(:json_encode_error), do: "Failed to encode data as JSON"

  def message({:feature_error, module, reason}),
    do: "Middleware #{inspect(module)} failed: #{inspect(reason)}"

  def message(:missing_tesla_client),
    do:
      "Tesla adapter requires a Tesla client. " <>
        "Use: HTTPower.get(url, adapter: {HTTPower.Adapter.Tesla, tesla_client})"

  def message(reason), do: inspect(reason)
end

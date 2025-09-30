defmodule HTTPower.TestInterceptor do
  @moduledoc false
  # Internal module for test request interception.
  # Keeps test logic separate from production adapter code.

  @doc """
  Intercepts a request if HTTPower.Test is enabled, otherwise returns :continue.
  """
  def intercept(method, url, body, headers) do
    if test_enabled?() do
      {:intercepted, HTTPower.Test.execute_stub(method, url, body, headers)}
    else
      :continue
    end
  end

  if Mix.env() == :test do
    defp test_enabled?, do: HTTPower.Test.mock_enabled?()
  else
    defp test_enabled?, do: false
  end
end

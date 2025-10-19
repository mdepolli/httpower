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

  defp test_enabled? do
    Code.ensure_loaded?(HTTPower.Test) and HTTPower.Test.mock_enabled?()
  end
end

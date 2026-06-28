defmodule HTTPower.Test.Keys do
  @moduledoc false
  # Unique, readable keys for tests that exercise a singleton middleware
  # GenServer / shared ETS table (CircuitBreaker, RateLimiter, Dedup). Giving
  # each test its own key means suites can run `async: true` without clobbering
  # each other's state — no global table wipe needed for isolation.

  @doc """
  A process- and time-unique key, prefixed for readable failure output
  (e.g. `"cb_57"`). Use one prefix per concept (`"cb"`, `"rl"`, `"bucket"`).
  """
  @spec uniq(String.t()) :: String.t()
  def uniq(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"
end

defmodule HTTPower.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Rate limiter GenServer
      HTTPower.RateLimiter,
      # Circuit breaker GenServer
      HTTPower.CircuitBreaker
    ]

    opts = [strategy: :one_for_one, name: HTTPower.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

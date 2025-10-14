defmodule HTTPower.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Rate limiter GenServer
        HTTPower.Feature.RateLimiter,
        # Circuit breaker GenServer
        HTTPower.Feature.CircuitBreaker,
        # Request deduplicator GenServer
        HTTPower.Feature.Dedup
      ] ++ finch_child()

    opts = [strategy: :one_for_one, name: HTTPower.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp finch_child do
    if Code.ensure_loaded?(Finch) do
      [{Finch, name: HTTPower.Finch, pools: finch_pools()}]
    else
      []
    end
  end

  defp finch_pools do
    Application.get_env(:httpower, :finch_pools, default_finch_pools())
  end

  defp default_finch_pools do
    %{
      default: [
        size: 10,
        count: System.schedulers_online()
      ]
    }
  end
end

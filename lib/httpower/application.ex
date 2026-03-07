defmodule HTTPower.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Test mock storage table — created in all envs so HTTPower.Test works
    # when HTTPower is a dependency (no Mix.env() available from Hex packages)
    if :ets.whereis(:httpower_test_stubs) == :undefined do
      :ets.new(:httpower_test_stubs, [:set, :public, :named_table, read_concurrency: true])
    end

    children =
      [
        # Rate limiter GenServer
        HTTPower.Middleware.RateLimiter,
        # Circuit breaker GenServer
        HTTPower.Middleware.CircuitBreaker,
        # Request deduplicator GenServer
        HTTPower.Middleware.Dedup
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

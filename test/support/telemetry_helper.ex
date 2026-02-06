defmodule HTTPower.TelemetryTestHelper do
  @moduledoc false

  def forward_event(event, measurements, metadata, %{test_pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  def agent_collect_event(_event, measurements, metadata, %{agent: agent}) do
    Agent.update(agent, fn events ->
      [%{measurements: measurements, metadata: metadata} | events]
    end)
  end

  def agent_collect_tuple(_event, measurements, metadata, %{agent: agent}) do
    Agent.update(agent, fn events ->
      [{measurements, metadata} | events]
    end)
  end

  def dedup_bypass_counter(event, measurements, _metadata, %{agent: agent}) do
    case event do
      [:httpower, :dedup, :cache_hit] ->
        bypassed = Map.get(measurements, :bypassed_rate_limit, 0)

        Agent.update(agent, fn state ->
          Map.update!(state, :rate_limit_bypassed, &(&1 + bypassed))
        end)

      [:httpower, :rate_limit, :ok] ->
        Agent.update(agent, fn state ->
          Map.update!(state, :rate_limit_consumed, &(&1 + 1))
        end)
    end
  end
end

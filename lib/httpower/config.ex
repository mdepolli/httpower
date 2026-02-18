defmodule HTTPower.Config do
  @moduledoc false

  @spec get(keyword(), atom(), atom(), term()) :: term()
  def get(config, key, app_key, default) do
    case Keyword.fetch(config, key) do
      {:ok, value} ->
        value

      :error ->
        Application.get_env(:httpower, app_key, [])
        |> Keyword.get(key, default)
    end
  end

  @spec enabled?(keyword(), atom(), boolean()) :: boolean()
  def enabled?(config, app_key, default \\ false) do
    get(config, :enabled, app_key, default)
  end
end

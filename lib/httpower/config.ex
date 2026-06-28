defmodule HTTPower.Config do
  @moduledoc false

  @doc """
  Resolves the effective config for an HTTPower middleware option at the request
  edge: the runtime application env for `option_key` (preserving dynamic
  override) merged with the request's normalized opt, the request opt winning.
  Returns a plain keyword list; callers supply their own defaults for absent keys.
  """
  @spec resolve(atom(), keyword()) :: keyword()
  def resolve(option_key, request_opts) do
    app_env = Application.get_env(:httpower, option_key, [])
    Keyword.merge(app_env, normalize_opt(Keyword.get(request_opts, option_key)))
  end

  defp normalize_opt(nil), do: []
  defp normalize_opt(true), do: [enabled: true]
  defp normalize_opt(false), do: [enabled: false]
  defp normalize_opt(config) when is_list(config), do: config
  defp normalize_opt(_), do: []
end

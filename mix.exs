defmodule HTTPower.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/mdepolli/httpower"

  def project do
    [
      app: :httpower,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "HTTPower",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.4.0"},
      {:plug, "~> 1.15", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    A reliable HTTP client that wraps Req with advanced features including
    test mode request blocking, smart retries, rate limiting, and circuit breaker patterns.
    Perfect for production applications that need bulletproof HTTP behavior.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["Marcelo De Polli"]
    ]
  end

  defp docs do
    [
      main: "HTTPower",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: ["README.md"]
    ]
  end
end

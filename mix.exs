defmodule HTTPower.MixProject do
  use Mix.Project

  @version "0.9.0"
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
      source_url: @source_url,
      test_coverage: [
        summary: [threshold: 75],
        ignore_modules: [
          # Adapters are thin wrappers around Req/Tesla with minimal logic.
          # They're thoroughly tested via integration tests (see test/httpower/adapter/*_test.exs),
          # but HTTPower.Test intercepts requests before adapter code executes in unit tests,
          # resulting in low direct coverage metrics despite comprehensive testing.
          HTTPower.Adapter.Req,
          HTTPower.Adapter.Tesla
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {HTTPower.Application, []}
    ]
  end

  defp deps do
    [
      # HTTP client adapters - at least one required
      {:req, "~> 0.4.0", optional: true},
      {:tesla, "~> 1.11", optional: true},
      # Development dependencies
      {:plug, "~> 1.15", only: :test},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    HTTP client library with advanced reliability patterns built-in. Features circuit breaker, rate limiting,
    PCI-compliant logging, and smart retries. Works with Req or Tesla adapters. Built for payment processing,
    microservices, and high-volume APIs.
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
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/migrating-from-tesla.md",
        "guides/migrating-from-req.md",
        "guides/configuration-reference.md",
        "guides/production-deployment.md"
      ],
      groups_for_extras: [
        "Migration Guides": [
          "guides/migrating-from-tesla.md",
          "guides/migrating-from-req.md"
        ],
        Guides: [
          "guides/configuration-reference.md",
          "guides/production-deployment.md"
        ]
      ]
    ]
  end
end

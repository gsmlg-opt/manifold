defmodule Manifold.Connectors.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_connectors,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :telemetry],
      mod: {Manifold.Connectors.Application, []}
    ]
  end

  defp deps do
    [
      {:manifold_core, in_umbrella: true},
      {:manifold_data, in_umbrella: true},
      {:manifold_accounts, in_umbrella: true},
      {:manifold_ingest, in_umbrella: true},
      {:manifold_mail, in_umbrella: true},
      {:oban, "~> 2.23"},
      {:req, "~> 0.7"},
      {:jason, "~> 1.4"},
      {:telemetry, "~> 1.3"}
    ]
  end
end

defmodule Manifold.Outbound.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_outbound,
      version: "0.6.8",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :telemetry],
      mod: {Manifold.Outbound.Application, []}
    ]
  end

  defp deps do
    [
      {:manifold_core, in_umbrella: true},
      {:manifold_data, in_umbrella: true},
      {:manifold_accounts, in_umbrella: true},
      {:manifold_connectors, in_umbrella: true},
      {:manifold_mail, in_umbrella: true},
      {:styx, "== 0.1.1"},
      {:plug, "~> 1.16", only: :test},
      {:telemetry, "~> 1.3"}
    ]
  end
end

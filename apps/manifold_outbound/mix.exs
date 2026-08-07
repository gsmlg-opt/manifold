defmodule Manifold.Outbound.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_outbound,
      version: "0.3.0",
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
      {:manifold_mail, in_umbrella: true},
      {:oban, "~> 2.20"},
      {:req, "~> 0.5"},
      {:telemetry, "~> 1.3"}
    ]
  end
end

defmodule Manifold.Ingest.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_ingest,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :telemetry],
      mod: {Manifold.Ingest.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:manifold_core, in_umbrella: true},
      {:manifold_data, in_umbrella: true},
      {:manifold_accounts, in_umbrella: true},
      {:manifold_storage, in_umbrella: true},
      {:manifold_mail, in_umbrella: true},
      {:manifold_security, in_umbrella: true},
      {:oban, "~> 2.23"},
      {:telemetry, "~> 1.3"}
    ]
  end
end

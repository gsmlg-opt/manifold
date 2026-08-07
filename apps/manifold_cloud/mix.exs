defmodule Manifold.Cloud.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_cloud,
      version: "0.3.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Manifold.Cloud.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:manifold_core, in_umbrella: true},
      {:manifold_data, in_umbrella: true},
      {:manifold_accounts, in_umbrella: true},
      {:manifold_storage, in_umbrella: true},
      {:manifold_ingest, in_umbrella: true},
      {:req, "~> 0.5"},
      {:plug, "~> 1.18", only: :test},
      {:oban, "~> 2.20"}
    ]
  end
end

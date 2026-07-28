defmodule Manifold.Data.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_data,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Manifold.Data.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:manifold_core, in_umbrella: true},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22.3"},
      {:oban, "~> 2.23"},
      {:telemetry, "~> 1.3"}
    ]
  end
end

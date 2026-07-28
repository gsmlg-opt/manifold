defmodule ManifoldWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_web,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {ManifoldWeb.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:manifold_accounts, in_umbrella: true},
      {:manifold_ingest, in_umbrella: true},
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:lazy_html, "~> 0.1", only: :test},
      {:phoenix_pubsub, "~> 2.2"},
      {:phoenix_duskmoon, "~> 9.9"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.8"},
      {:bun, "~> 1.4", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev}
    ]
  end

  defp aliases do
    [
      "assets.setup": ["cmd bun install"],
      "assets.deploy": [
        "tailwind manifold_web --minify",
        "bun manifold_web --minify",
        "phx.digest"
      ]
    ]
  end
end

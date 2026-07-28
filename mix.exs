defmodule Manifold.Umbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      elixir: "~> 1.18",
      elixirc_options: [warnings_as_errors: Mix.env() in [:dev, :test]],
      listeners: [Phoenix.CodeReloader],
      preferred_cli_env: [
        format: :dev,
        "format --check-formatted": :dev,
        test: :test,
        "test.all": :test
      ]
    ]
  end

  defp deps do
    []
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run apps/manifold_data/priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["do --app manifold_web cmd bun install"],
      "assets.deploy": [
        "do --app manifold_web tailwind manifold_web --minify + bun manifold_web --minify + phx.digest"
      ],
      "test.all": ["format --check-formatted", "compile --warnings-as-errors", "test"]
    ]
  end
end

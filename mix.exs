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
      releases: releases(),
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
      "assets.setup": ["npm.install"],
      "assets.build": ["duskmoon_bundler.build manifold_web --tailwind"],
      "assets.deploy": [
        "duskmoon_bundler.build manifold_web --tailwind",
        &digest_web_assets/1
      ],
      "test.all": ["format --check-formatted", "compile --warnings-as-errors", "test"]
    ]
  end

  defp digest_web_assets(_args) do
    {:ok, _} = Application.ensure_all_started(:phoenix)
    static_path = Path.expand("apps/manifold_web/priv/static", __DIR__)

    case Phoenix.Digester.compile(static_path, static_path, true) do
      :ok ->
        Mix.Project.in_project(:manifold_web, Path.expand("apps/manifold_web", __DIR__), fn _ ->
          Mix.Project.build_structure()
        end)

        Mix.shell().info([:green, "Check your digested files at #{inspect(static_path)}"])

      {:error, :invalid_path} ->
        Mix.raise("The input path #{inspect(static_path)} does not exist")
    end
  end

  defp releases do
    [
      manifold: [
        applications: [
          manifold_core: :permanent,
          manifold_data: :permanent,
          manifold_accounts: :permanent,
          manifold_storage: :permanent,
          manifold_mail: :permanent,
          manifold_security: :permanent,
          manifold_outbound: :permanent,
          manifold_ingest: :permanent,
          manifold_cloud: :permanent,
          manifold_connectors: :permanent,
          manifold_smtp: :permanent,
          manifold_web: :permanent
        ]
      ],
      manifold_edge: [
        applications: [
          manifold_core: :permanent,
          manifold_storage: :permanent,
          manifold_edge: :permanent,
          manifold_smtp: :permanent
        ]
      ]
    ]
  end
end

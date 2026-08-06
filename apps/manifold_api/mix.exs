defmodule ManifoldAPI.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_api,
      version: "0.2.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ManifoldAPI.Application, []}
    ]
  end

  defp deps do
    [
      {:manifold_accounts, in_umbrella: true},
      {:manifold_mail, in_umbrella: true},
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_pubsub, "~> 2.2"},
      {:absinthe, "~> 1.7"},
      {:absinthe_plug, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.8"},
      {:telemetry, "~> 1.3"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end

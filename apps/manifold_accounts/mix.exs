defmodule Manifold.Accounts.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_accounts,
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
      mod: {Manifold.Accounts.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:manifold_core, in_umbrella: true},
      {:manifold_data, in_umbrella: true},
      {:bcrypt_elixir, "~> 3.3"},
      {:jason, "~> 1.4"}
    ]
  end
end

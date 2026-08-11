defmodule Manifold.AccountLifecycle.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_account_lifecycle,
      version: "0.3.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Manifold.AccountLifecycle.Application, []}
    ]
  end

  defp deps do
    [
      {:manifold_accounts, in_umbrella: true},
      {:manifold_connectors, in_umbrella: true},
      {:manifold_ingest, in_umbrella: true},
      {:manifold_mail, in_umbrella: true},
      {:manifold_outbound, in_umbrella: true},
      {:manifold_security, in_umbrella: true},
      {:manifold_storage, in_umbrella: true},
      {:manifold_data, in_umbrella: true},
      {:oban, "~> 2.23"}
    ]
  end
end

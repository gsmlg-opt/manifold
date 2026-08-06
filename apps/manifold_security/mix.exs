defmodule Manifold.Security.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_security,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :telemetry],
      mod: {Manifold.Security.Application, []}
    ]
  end

  defp deps do
    [
      {:manifold_core, in_umbrella: true},
      {:manifold_data, in_umbrella: true},
      {:manifold_mail, in_umbrella: true},
      {:manifold_storage, in_umbrella: true},
      {:oban, "~> 2.23"},
      {:telemetry, "~> 1.3"}
    ]
  end
end

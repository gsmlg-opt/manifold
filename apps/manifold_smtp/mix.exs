defmodule Manifold.SMTP.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_smtp,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :telemetry],
      mod: {Manifold.SMTP.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:manifold_core, in_umbrella: true},
      {:manifold_accounts, in_umbrella: true, only: :test, runtime: false},
      {:manifold_ingest, in_umbrella: true, only: :test, runtime: false},
      {:gen_smtp, "~> 1.3"},
      {:telemetry, "~> 1.3"}
    ]
  end
end

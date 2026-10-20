defmodule Manifold.Core.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_core,
      version: "0.6.6",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :logger],
      mod: {Manifold.Core.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:http_fetch, "== 0.21.10"},
      {:jason, "~> 1.4"},
      {:tzdata, "~> 1.2"},
      {:plug, "~> 1.0", only: :test}
    ]
  end
end

defmodule Manifold.Calendars.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_calendars,
      version: "0.5.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [{:manifold_data, in_umbrella: true}]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end

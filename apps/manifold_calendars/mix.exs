defmodule Manifold.Calendars.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_calendars,
      version: "0.6.9",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:manifold_data, in_umbrella: true},
        {:tzdata, "~> 1.2"},
        {:rrule, "~> 0.7"},
        # rrule's precompiled loader also works with the loader required by our bundler.
        {:rustler_precompiled, "~> 0.10", override: true},
        {:rustler, "~> 0.38", override: true, runtime: false}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end

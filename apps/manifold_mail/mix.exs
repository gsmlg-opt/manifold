defmodule Manifold.Mail.MixProject do
  use Mix.Project

  def project do
    [
      app: :manifold_mail,
      version: "0.2.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :telemetry],
      mod: {Manifold.Mail.Application, []}
    ]
  end

  defp deps do
    [
      {:manifold_core, in_umbrella: true},
      {:manifold_data, in_umbrella: true},
      {:manifold_storage, in_umbrella: true},
      {:mail, "~> 0.5.2"},
      {:codepagex, "~> 0.1.13"},
      {:html_sanitize_ex, "~> 1.5.2"},
      {:ex_marcel, "~> 0.2.0"},
      {:telemetry, "~> 1.3"}
    ]
  end
end

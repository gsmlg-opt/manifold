defmodule Mix.Tasks.Manifold.Run do
  @moduledoc """
  Starts the Manifold development server.

  Always runs `mix compile --force` first, then delegates to `mix phx.server`,
  which starts the Phoenix endpoint and the umbrella supervision tree,
  including the SMTP listener when it is enabled.
  """

  use Mix.Task

  @shortdoc "Force-compiles, then starts Phoenix and the Manifold SMTP listener"

  @impl Mix.Task
  def run(args) do
    Mix.Task.reenable("compile")
    Mix.Task.run("compile", ["--force"])
    Mix.Task.run("phx.server", args)
  end
end

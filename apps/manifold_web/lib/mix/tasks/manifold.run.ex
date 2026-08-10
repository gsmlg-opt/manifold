defmodule Mix.Tasks.Manifold.Run do
  @moduledoc """
  Starts the Manifold development server.

  Always runs `mix compile --force` first, then delegates to `mix phx.server`,
  which starts the Phoenix endpoint and the mail-client umbrella applications.
  """

  use Mix.Task

  @shortdoc "Force-compiles and starts the Manifold mail-client runtime"

  @impl Mix.Task
  def run(args) do
    Mix.Task.reenable("compile")
    Mix.Task.run("compile", ["--force"])
    Mix.Task.run("phx.server", args)
  end
end

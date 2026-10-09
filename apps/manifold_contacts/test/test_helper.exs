ExUnit.start()
Application.ensure_all_started(:manifold_data)

try do
  Mix.Task.run("ecto.create", ["--quiet", "-r", "Manifold.Repo"])
rescue
  _ -> :ok
end

Mix.Task.run("ecto.migrate", ["--quiet", "-r", "Manifold.Repo"])
Ecto.Adapters.SQL.Sandbox.mode(Manifold.Repo, :manual)
Code.require_file("../../../test/support/data_case.exs", __DIR__)

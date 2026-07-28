Application.ensure_all_started(:manifold_data)

try do
  Mix.Task.run("ecto.create", ["--quiet"])
rescue
  _ -> :ok
end

Mix.Task.run("ecto.migrate", ["--quiet"])
Ecto.Adapters.SQL.Sandbox.mode(Manifold.Repo, :manual)

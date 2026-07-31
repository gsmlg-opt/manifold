repo_config =
  if url = System.get_env("MANIFOLD_EDGE_TEST_DATABASE_URL") do
    [url: url]
  else
    [
      username: System.get_env("POSTGRES_USER", "manifold_dev"),
      password: System.get_env("POSTGRES_PASSWORD", "manifold_dev"),
      database: "manifold_edge_test#{System.get_env("MIX_TEST_PARTITION")}",
      hostname: System.get_env("POSTGRES_HOST", "localhost"),
      port: String.to_integer(System.get_env("POSTGRES_PORT", "5432"))
    ]
  end

repo_config =
  if System.get_env("DEVENV_RUNTIME") not in [nil, ""] do
    case System.get_env("POSTGRES_SOCKET_DIR") do
      nil -> repo_config
      socket_dir -> Keyword.put(repo_config, :socket_dir, socket_dir)
    end
  else
    repo_config
  end

repo_config =
  Keyword.merge(repo_config,
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2
  )

Application.put_env(:manifold_edge, Manifold.Edge.Repo, repo_config)

case Ecto.Adapters.Postgres.storage_up(repo_config) do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

{:ok, _repo} = Manifold.Edge.Repo.start_link()

Ecto.Migrator.run(
  Manifold.Edge.Repo,
  Application.app_dir(:manifold_edge, "priv/repo/migrations"),
  :up,
  all: true
)

ExUnit.start()

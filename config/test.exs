import Config

repo_config = [
  url: System.get_env("TEST_DATABASE_URL"),
  username: System.get_env("POSTGRES_USER", "manifold_dev"),
  password: System.get_env("POSTGRES_PASSWORD", "manifold_dev"),
  database:
    System.get_env("POSTGRES_TEST_DB", "manifold_test#{System.get_env("MIX_TEST_PARTITION")}"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2
]

repo_config =
  if socket_dir = System.get_env("POSTGRES_SOCKET_DIR") do
    Keyword.put(repo_config, :socket_dir, socket_dir)
  else
    repo_config
  end

config :manifold_data, Manifold.Repo, repo_config

config :manifold_data, Oban, testing: :manual, queues: false, plugins: false

config :manifold_smtp, enabled: false, port: 2526

config :manifold_storage,
  spool_dir: Path.expand("../tmp/test_spool", __DIR__),
  raw_store_dir: Path.expand("../tmp/test_raw_store", __DIR__)

config :manifold_web, ManifoldWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test-secret-key-base-test-secret-key-base-test-secret-key-base-test-secret-key-base",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

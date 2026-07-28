import Config

repo_config = [
  url: System.get_env("DATABASE_URL"),
  username: System.get_env("POSTGRES_USER", "manifold_dev"),
  password: System.get_env("POSTGRES_PASSWORD", "manifold_dev"),
  database: System.get_env("POSTGRES_DB", "manifold_dev"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  show_sensitive_data_on_connection_error: true,
  stacktrace: true,
  pool_size: 10
]

repo_config =
  if socket_dir = System.get_env("POSTGRES_SOCKET_DIR") do
    Keyword.put(repo_config, :socket_dir, socket_dir)
  else
    repo_config
  end

config :manifold_data, Manifold.Repo, repo_config

config :manifold_web, ManifoldWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev-secret-key-base-dev-secret-key-base-dev-secret-key-base-dev-secret-key-base",
  watchers: [
    tailwind: {Tailwind, :install_and_run, [:manifold_web, ~w(--watch)]},
    bun: {Bun, :install_and_run, [:manifold_web, ~w(--sourcemap=inline --watch)]}
  ]

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

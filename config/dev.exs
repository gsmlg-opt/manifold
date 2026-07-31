import Config

# Compile-time defaults only. Env overrides belong in config/runtime.exs.
config :manifold_data, Manifold.Repo,
  username: "manifold_dev",
  password: "manifold_dev",
  database: "manifold_dev",
  hostname: "localhost",
  port: 5432,
  show_sensitive_data_on_connection_error: true,
  stacktrace: true,
  pool_size: 10

config :manifold_connectors,
  encryption_key: "G6HVBr8ZblWE1sHBF/vCyXH/aWOJgmExT8ECM+yLPbc="

config :manifold_web, ManifoldWeb.Endpoint,
  # Include the listener port in `:url` so OAuth callback URIs match the
  # provider-console registrations documented as http://localhost:4290/...
  url: [host: "localhost", port: 4290],
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4290],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev-secret-key-base-dev-secret-key-base-dev-secret-key-base-dev-secret-key-base",
  watchers: [
    duskmoon_bundler: {Mix.Tasks.DuskmoonBundler.Dev, :run, [["manifold_web"]]}
  ]

config :manifold_api, ManifoldAPI.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4292],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev-api-secret-key-base-dev-api-secret-key-base-dev-api-secret-key-base-dev"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime

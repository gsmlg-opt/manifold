import Config

# Compile-time defaults only. Env overrides belong in config/runtime.exs.
config :manifold_data, Manifold.Repo,
  username: "manifold_dev",
  password: "manifold_dev",
  database: "manifold_test",
  hostname: "localhost",
  port: 5432,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :manifold_data, Oban, testing: :manual, queues: false, plugins: false

config :manifold_connectors,
  encryption_key: "A/6Bm4le6HQiXyh+gE1NQr2+RLEcEpZ/JSPBt4y1Lrk=",
  providers: [
    gmail: [
      authorization_url: "https://accounts.google.invalid/authorize",
      token_url: "https://accounts.google.invalid/token",
      userinfo_url: "https://openidconnect.invalid/v1/userinfo",
      base_url: "https://gmail.invalid"
    ],
    microsoft: [
      authorization_url: "https://login.microsoft.invalid/authorize",
      token_url: "https://login.microsoft.invalid/token",
      base_url: "https://graph.microsoft.invalid/v1.0",
      tenant: "organizations"
    ]
  ]

config :manifold_smtp, enabled: false, port: 2526

config :manifold_storage,
  spool_dir: Path.expand("../tmp/test_spool", __DIR__),
  raw_store_dir: Path.expand("../tmp/test_raw_store", __DIR__),
  blob_store_dir: Path.expand("../tmp/test_blob_store", __DIR__)

config :manifold_web, ManifoldWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base:
    "test-secret-key-base-test-secret-key-base-test-secret-key-base-test-secret-key-base",
  server: false

config :manifold_api, ManifoldAPI.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  secret_key_base: "test-api-secret-key-base-test-api-secret-key-base-test-api-secret-key-base",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

import Config

config :manifold_data,
  ecto_repos: [Manifold.Repo],
  oban_enabled: config_env() != :test,
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true]

config :manifold_data, Manifold.Repo,
  migration_primary_key: [name: :id, type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec]

config :manifold_data, Oban,
  repo: Manifold.Repo,
  queues: [archive: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Cron, crontab: [{"*/5 * * * *", Manifold.Ingest.Jobs.ReconcileSpool}]}
  ]

config :manifold_storage,
  spool_dir: Path.expand("../priv/spool/#{config_env()}", __DIR__),
  spool_min_free_bytes: 0,
  raw_store_backend: Manifold.Storage.RawStore.Local,
  raw_store_dir: Path.expand("../priv/raw_store/#{config_env()}", __DIR__)

config :manifold_ingest,
  reconciler_enabled: config_env() != :test,
  orphan_retention_seconds: 3600

config :manifold_smtp,
  enabled: config_env() != :test,
  hostname: "localhost",
  bind: "127.0.0.1",
  port: 2525,
  max_message_bytes: 25 * 1024 * 1024,
  max_recipients: 100,
  tls_certfile: nil,
  tls_keyfile: nil

config :manifold_web,
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true],
  ecto_repos: [Manifold.Repo]

config :manifold_web, ManifoldWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ManifoldWeb.ErrorHTML, json: ManifoldWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Manifold.PubSub,
  live_view: [signing_salt: "manifold-local-signing-salt"]

config :phoenix, :json_library, Jason

config :bun,
  version: "1.3.13",
  manifold_web: [
    args:
      ~w(build assets/js/app.js --outdir=priv/static/assets --external /fonts/* --external /images/*),
    cd: Path.expand("../apps/manifold_web", __DIR__)
  ]

config :tailwind,
  version: "4.3.3",
  manifold_web: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/app.css),
    cd: Path.expand("../apps/manifold_web", __DIR__)
  ]

import_config "#{config_env()}.exs"

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
  queues: [
    archive: 10,
    mail_parse: 2,
    security: 2,
    outbound: 5,
    cloud_ingress: 2,
    connectors: 2
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Cron,
     crontab: [
       {"*/5 * * * *", Manifold.Cloud.Jobs.PublishRoutes},
       {"* * * * *", Manifold.Cloud.Jobs.PullDeliveries},
       {"*/5 * * * *", Manifold.Connectors.Jobs.PollAccounts}
     ]}
  ]

config :manifold_connectors,
  adapters: [
    gmail: Manifold.Connectors.Provider.Gmail,
    microsoft: Manifold.Connectors.Provider.MicrosoftGraph
  ],
  activity_log_dir: "log/connectors",
  activity_log_retention_days: 14,
  providers: [
    gmail: [
      authorization_url: "https://accounts.google.com/o/oauth2/v2/auth",
      token_url: "https://oauth2.googleapis.com/token",
      userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
      base_url: "https://gmail.googleapis.com"
    ],
    microsoft: [
      authorization_url: "https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize",
      token_url: "https://login.microsoftonline.com/organizations/oauth2/v2.0/token",
      base_url: "https://graph.microsoft.com/v1.0",
      tenant: "organizations"
    ]
  ]

config :manifold_storage,
  spool_dir: Path.expand("../priv/spool/#{config_env()}", __DIR__),
  spool_min_free_bytes: 0,
  raw_store_backend: Manifold.Storage.RawStore.Local,
  raw_store_dir: Path.expand("../priv/raw_store/#{config_env()}", __DIR__),
  blob_store_backend: Manifold.Storage.BlobStore.Local,
  blob_store_dir: Path.expand("../priv/blob_store/#{config_env()}", __DIR__)

config :manifold_mail,
  # Bumped for GB2312/GBK/GB18030 charset decoding (CP936) and RFC2047 fallback.
  # v4 re-runs rows stamped earlier before EncodedWord fallback existed.
  parser_version: 4,
  sanitizer_version: 1,
  max_raw_bytes: 25 * 1024 * 1024,
  max_header_bytes: 256 * 1024,
  max_headers: 1_000,
  max_mime_depth: 20,
  max_parts: 500,
  max_decoded_bytes: 100 * 1024 * 1024,
  max_attachment_bytes: 50 * 1024 * 1024,
  parse_timeout_ms: 30_000,
  parse_max_heap_words: 64_000_000

config :manifold_ingest,
  reconciler_enabled: config_env() != :test,
  orphan_retention_seconds: 3600,
  partial_retention_seconds: 3600

config :manifold_outbound,
  provider_adapter: Manifold.Outbound.Provider.Resend,
  provider_config: []

config :manifold_security,
  evaluation_version: 1,
  adapter_config: []

config :manifold_smtp,
  enabled: config_env() != :test,
  hostname: "localhost",
  bind: "127.0.0.1",
  port: 2525,
  max_message_bytes: 25 * 1024 * 1024,
  max_recipients: 100,
  resolver: Manifold.Accounts,
  ingest: Manifold.Ingest,
  max_connections: 16,
  acceptors: 4,
  admission: [
    max_connections_per_peer: 8,
    connection_rate_limit: 60,
    connection_rate_window_ms: 60_000,
    transaction_rate_limit: 120,
    transaction_rate_window_ms: 60_000
  ],
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

config :manifold_api,
  generators: [timestamp_type: :utc_datetime_usec, binary_id: true],
  ecto_repos: [Manifold.Repo]

config :manifold_api, ManifoldAPI.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: ManifoldAPI.ErrorJSON],
    layout: false
  ],
  pubsub_server: ManifoldAPI.PubSub

config :phoenix, :json_library, Jason

config :codepagex,
  encodings: [
    :ascii,
    :iso_8859_1,
    :iso_8859_2,
    :iso_8859_3,
    :iso_8859_4,
    :iso_8859_5,
    :iso_8859_6,
    :iso_8859_7,
    :iso_8859_8,
    :iso_8859_9,
    :iso_8859_10,
    :iso_8859_11,
    :iso_8859_13,
    :iso_8859_14,
    :iso_8859_15,
    :iso_8859_16,
    "VENDORS/MICSFT/WINDOWS/CP1252",
    # GB2312 / GBK / commonly-labeled GB18030 email bodies (QQ Exmail, etc.)
    "VENDORS/MICSFT/WINDOWS/CP936"
  ]

config :duskmoon_bundler,
  root: Path.expand("../apps/manifold_web/assets", __DIR__),
  sources: ["**/*.{js,ts,jsx,tsx}"]

config :duskmoon_bundler, :manifold_web,
  root: Path.expand("../apps/manifold_web/assets", __DIR__),
  entry: Path.expand("../apps/manifold_web/assets/js/app.js", __DIR__),
  outdir: Path.expand("../apps/manifold_web/priv/static/assets", __DIR__),
  resolve_dirs: [
    Path.expand("../apps", __DIR__),
    Path.expand("../deps", __DIR__),
    Path.expand("..", __DIR__)
  ],
  sourcemap: :hidden,
  target: :es2020,
  tailwind: [
    css: Path.expand("../apps/manifold_web/assets/css/app.css", __DIR__),
    sources: [
      %{base: Path.expand("../apps/manifold_web/lib", __DIR__), pattern: "**/*.{ex,exs,heex}"},
      %{
        base: Path.expand("../apps/manifold_web/assets", __DIR__),
        pattern: "**/*.{css,js,ts,jsx,tsx}"
      }
    ]
  ]

config :duskmoon_bundler, :format,
  print_width: 100,
  semi: true,
  single_quote: false,
  trailing_comma: :es5,
  arrow_parens: :always

config :duskmoon_bundler, :lint,
  rules: %{
    "no-debugger" => :deny,
    "eqeqeq" => :deny
  }

import_config "#{config_env()}.exs"

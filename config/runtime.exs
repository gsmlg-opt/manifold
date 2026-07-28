import Config

if System.get_env("MIX_BUN_PATH") do
  config :bun, path: System.fetch_env!("MIX_BUN_PATH")
end

if System.get_env("MIX_TAILWIND_PATH") do
  config :tailwind, path: System.fetch_env!("MIX_TAILWIND_PATH")
end

database_url = System.get_env("DATABASE_URL")

if database_url do
  repo_config = [
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
  ]

  repo_config =
    if socket_dir = System.get_env("POSTGRES_SOCKET_DIR") do
      Keyword.put(repo_config, :socket_dir, socket_dir)
    else
      repo_config
    end

  config :manifold_data, Manifold.Repo, repo_config
end

config :manifold_smtp,
  hostname: System.get_env("MANIFOLD_SMTP_HOSTNAME", "localhost"),
  bind: System.get_env("MANIFOLD_SMTP_BIND", "127.0.0.1"),
  port: String.to_integer(System.get_env("MANIFOLD_SMTP_PORT", "2525")),
  max_message_bytes:
    String.to_integer(System.get_env("MANIFOLD_SMTP_MAX_MESSAGE_BYTES", "26214400")),
  max_recipients: String.to_integer(System.get_env("MANIFOLD_SMTP_MAX_RECIPIENTS", "100")),
  tls_certfile: System.get_env("MANIFOLD_SMTP_TLS_CERTFILE"),
  tls_keyfile: System.get_env("MANIFOLD_SMTP_TLS_KEYFILE")

raw_store_backend =
  case System.get_env("MANIFOLD_RAW_STORE_BACKEND", "local") do
    "local" -> Manifold.Storage.RawStore.Local
    other -> raise "unsupported MANIFOLD_RAW_STORE_BACKEND=#{other}"
  end

config :manifold_storage,
  spool_dir:
    System.get_env("MANIFOLD_SPOOL_DIR", Path.expand("../priv/spool/#{config_env()}", __DIR__)),
  spool_min_free_bytes: String.to_integer(System.get_env("MANIFOLD_SPOOL_MIN_FREE_BYTES", "0")),
  raw_store_backend: raw_store_backend,
  raw_store_dir:
    System.get_env(
      "MANIFOLD_RAW_STORE_DIR",
      Path.expand("../priv/raw_store/#{config_env()}", __DIR__)
    )

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "SECRET_KEY_BASE is missing. Generate one with mix phx.gen.secret."

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT", "4000"))

  config :manifold_web, ManifoldWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0}, port: port],
    secret_key_base: secret_key_base,
    server: true
end

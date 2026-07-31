import Config

release_name = System.get_env("RELEASE_NAME", "manifold")
edge_release? = release_name == "manifold_edge" or System.get_env("MANIFOLD_ROLE") == "edge"

unless config_env() == :test do
  if database_url = System.get_env("DATABASE_URL") do
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
end

config :manifold_smtp,
  hostname: System.get_env("MANIFOLD_SMTP_HOSTNAME", "localhost"),
  bind: System.get_env("MANIFOLD_SMTP_BIND", "127.0.0.1"),
  port:
    String.to_integer(
      System.get_env("MANIFOLD_SMTP_PORT", if(edge_release?, do: "25", else: "2525"))
    ),
  max_message_bytes:
    String.to_integer(System.get_env("MANIFOLD_SMTP_MAX_MESSAGE_BYTES", "26214400")),
  max_recipients: String.to_integer(System.get_env("MANIFOLD_SMTP_MAX_RECIPIENTS", "100")),
  max_connections: String.to_integer(System.get_env("MANIFOLD_SMTP_MAX_CONNECTIONS", "16")),
  acceptors: String.to_integer(System.get_env("MANIFOLD_SMTP_ACCEPTORS", "4")),
  admission: [
    max_connections_per_peer:
      String.to_integer(System.get_env("MANIFOLD_SMTP_MAX_CONNECTIONS_PER_PEER", "8")),
    connection_rate_limit:
      String.to_integer(System.get_env("MANIFOLD_SMTP_CONNECTION_RATE_LIMIT", "60")),
    connection_rate_window_ms:
      String.to_integer(System.get_env("MANIFOLD_SMTP_CONNECTION_RATE_WINDOW_MS", "60000")),
    transaction_rate_limit:
      String.to_integer(System.get_env("MANIFOLD_SMTP_TRANSACTION_RATE_LIMIT", "120")),
    transaction_rate_window_ms:
      String.to_integer(System.get_env("MANIFOLD_SMTP_TRANSACTION_RATE_WINDOW_MS", "60000"))
  ],
  tls_certfile: System.get_env("MANIFOLD_SMTP_TLS_CERTFILE"),
  tls_keyfile: System.get_env("MANIFOLD_SMTP_TLS_KEYFILE")

if edge_release? do
  edge_database_url =
    System.get_env("MANIFOLD_EDGE_DATABASE_URL") ||
      System.get_env("DATABASE_URL") ||
      raise "MANIFOLD_EDGE_DATABASE_URL or DATABASE_URL is required for manifold_edge"

  edge_api_url =
    System.get_env("MANIFOLD_EDGE_API_URL") ||
      raise "MANIFOLD_EDGE_API_URL is required and must use https"

  edge_uri = URI.parse(edge_api_url)

  if edge_uri.scheme != "https" or is_nil(edge_uri.authority) do
    raise "MANIFOLD_EDGE_API_URL must be an absolute https URL"
  end

  edge_secret =
    System.get_env("MANIFOLD_EDGE_SHARED_SECRET") ||
      raise "MANIFOLD_EDGE_SHARED_SECRET is required for manifold_edge"

  if byte_size(edge_secret) < 32 do
    raise "MANIFOLD_EDGE_SHARED_SECRET must contain at least 32 bytes"
  end

  edge_installation_id =
    System.get_env("MANIFOLD_EDGE_INSTALLATION_ID") ||
      raise "MANIFOLD_EDGE_INSTALLATION_ID is required for manifold_edge"

  config :manifold_edge, Manifold.Edge.Repo,
    url: edge_database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))

  config :manifold_edge,
    api_server: true,
    reconciler_enabled: true,
    api_bind: System.get_env("MANIFOLD_EDGE_API_BIND", "127.0.0.1"),
    api_port: String.to_integer(System.get_env("MANIFOLD_EDGE_API_PORT", "4291")),
    api: [
      installation_id: edge_installation_id,
      authority: edge_uri.authority,
      shared_secret: edge_secret,
      max_clock_skew_seconds:
        String.to_integer(System.get_env("MANIFOLD_EDGE_MAX_CLOCK_SKEW_SECONDS", "300")),
      max_request_bytes:
        String.to_integer(System.get_env("MANIFOLD_EDGE_MAX_REQUEST_BYTES", "2097152"))
    ]

  config :manifold_smtp,
    resolver: Manifold.Edge.SMTP,
    ingest: Manifold.Edge.SMTP
end

if not edge_release? and config_env() != :test do
  if edge_api_url = System.get_env("MANIFOLD_EDGE_API_URL") do
    edge_uri = URI.parse(edge_api_url)

    if edge_uri.scheme != "https" or is_nil(edge_uri.authority) do
      raise "MANIFOLD_EDGE_API_URL must be an absolute https URL"
    end

    local_edge_secret =
      System.get_env("MANIFOLD_EDGE_SHARED_SECRET") ||
        raise("MANIFOLD_EDGE_SHARED_SECRET is required when cloud ingress is configured")

    if byte_size(local_edge_secret) < 32 do
      raise "MANIFOLD_EDGE_SHARED_SECRET must contain at least 32 bytes"
    end

    config :manifold_cloud,
      source: [
        source_id: System.get_env("MANIFOLD_EDGE_SOURCE_ID", "default-edge"),
        base_url: String.trim_trailing(edge_api_url, "/"),
        authority: edge_uri.authority,
        installation_id:
          System.get_env("MANIFOLD_EDGE_INSTALLATION_ID") ||
            raise("MANIFOLD_EDGE_INSTALLATION_ID is required when cloud ingress is configured"),
        secret: local_edge_secret
      ]
  end
end

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
    ),
  blob_store_backend: Manifold.Storage.BlobStore.Local,
  blob_store_dir:
    System.get_env(
      "MANIFOLD_BLOB_STORE_DIR",
      Path.expand("../priv/blob_store/#{config_env()}", __DIR__)
    )

resend_config =
  []
  |> then(fn config ->
    case System.get_env("RESEND_API_KEY") do
      nil -> config
      api_key -> Keyword.put(config, :api_key, api_key)
    end
  end)
  |> then(fn config ->
    case System.get_env("RESEND_WEBHOOK_SECRET") do
      nil -> config
      secret -> Keyword.put(config, :webhook_secret, secret)
    end
  end)
  |> then(fn config ->
    case System.get_env("RESEND_API_BASE_URL") do
      nil -> config
      base_url -> Keyword.put(config, :base_url, base_url)
    end
  end)

config :manifold_outbound,
  provider_adapter: Manifold.Outbound.Provider.Resend,
  provider_config: resend_config

if not edge_release? do
  connector_encryption_key =
    case {config_env(), System.get_env("MANIFOLD_CONNECTOR_ENCRYPTION_KEY")} do
      {:prod, nil} ->
        raise "MANIFOLD_CONNECTOR_ENCRYPTION_KEY is required for the manifold release"

      {_environment, key} ->
        key
    end

  if connector_encryption_key do
    case Base.decode64(connector_encryption_key) do
      {:ok, key} when byte_size(key) == 32 ->
        :ok

      _invalid ->
        raise "MANIFOLD_CONNECTOR_ENCRYPTION_KEY must be Base64 encoding of exactly 32 bytes"
    end
  end

  https_endpoint! = fn env_name, default ->
    endpoint = System.get_env(env_name, default)
    uri = URI.parse(endpoint)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo) and is_nil(uri.fragment) do
      String.trim_trailing(endpoint, "/")
    else
      raise "#{env_name} must be an absolute https URL without credentials or a fragment"
    end
  end

  provider_credentials! = fn provider, client_id_env, client_secret_env, build_config ->
    case {System.get_env(client_id_env), System.get_env(client_secret_env)} do
      {nil, nil} ->
        nil

      {client_id, client_secret}
      when is_binary(client_id) and client_id != "" and is_binary(client_secret) and
             client_secret != "" ->
        build_config.(client_id, client_secret)

      _incomplete ->
        raise "#{client_id_env} and #{client_secret_env} must be configured together for #{provider}"
    end
  end

  gmail_config =
    provider_credentials!.(
      "Gmail",
      "MANIFOLD_GMAIL_CLIENT_ID",
      "MANIFOLD_GMAIL_CLIENT_SECRET",
      fn client_id, client_secret ->
        [
          client_id: client_id,
          client_secret: client_secret,
          authorization_url:
            https_endpoint!.(
              "MANIFOLD_GMAIL_AUTHORIZATION_URL",
              "https://accounts.google.com/o/oauth2/v2/auth"
            ),
          token_url:
            https_endpoint!.(
              "MANIFOLD_GMAIL_TOKEN_URL",
              "https://oauth2.googleapis.com/token"
            ),
          userinfo_url:
            https_endpoint!.(
              "MANIFOLD_GMAIL_USERINFO_URL",
              "https://openidconnect.googleapis.com/v1/userinfo"
            ),
          base_url:
            https_endpoint!.(
              "MANIFOLD_GMAIL_API_BASE_URL",
              "https://gmail.googleapis.com"
            )
        ]
      end
    )

  microsoft_tenant = System.get_env("MANIFOLD_MICROSOFT_TENANT", "organizations")

  unless Regex.match?(~r/\A[A-Za-z0-9.-]+\z/, microsoft_tenant) do
    raise "MANIFOLD_MICROSOFT_TENANT contains unsupported characters"
  end

  microsoft_config =
    provider_credentials!.(
      "Microsoft",
      "MANIFOLD_MICROSOFT_CLIENT_ID",
      "MANIFOLD_MICROSOFT_CLIENT_SECRET",
      fn client_id, client_secret ->
        tenant_base = "https://login.microsoftonline.com/#{microsoft_tenant}/oauth2/v2.0"

        [
          client_id: client_id,
          client_secret: client_secret,
          authorization_url:
            https_endpoint!.(
              "MANIFOLD_MICROSOFT_AUTHORIZATION_URL",
              tenant_base <> "/authorize"
            ),
          token_url:
            https_endpoint!.(
              "MANIFOLD_MICROSOFT_TOKEN_URL",
              tenant_base <> "/token"
            ),
          base_url:
            https_endpoint!.(
              "MANIFOLD_MICROSOFT_API_BASE_URL",
              "https://graph.microsoft.com/v1.0"
            ),
          tenant: microsoft_tenant
        ]
      end
    )

  connector_providers =
    [gmail: gmail_config, microsoft: microsoft_config]
    |> Enum.reject(fn {_provider, provider_config} -> is_nil(provider_config) end)

  connector_config =
    [providers: connector_providers]
    |> then(fn config ->
      if connector_encryption_key,
        do: Keyword.put(config, :encryption_key, connector_encryption_key),
        else: config
    end)

  config :manifold_connectors, connector_config

  if config_env() == :prod do
    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise "SECRET_KEY_BASE is missing. Generate one with mix phx.gen.secret."

    host = System.get_env("PHX_HOST") || "localhost"
    port = String.to_integer(System.get_env("PORT", "4290"))
    api_port = String.to_integer(System.get_env("API_PORT", "4292"))

    config :manifold_web, ManifoldWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [ip: {0, 0, 0, 0}, port: port],
      secret_key_base: secret_key_base,
      server: true

    config :manifold_api, ManifoldAPI.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [ip: {0, 0, 0, 0}, port: api_port],
      secret_key_base: secret_key_base,
      server: true
  end
end

defmodule Manifold.ConfigTest do
  use ExUnit.Case, async: false

  @runtime_env_vars ~w(
    RELEASE_NAME
    MANIFOLD_ROLE
    MANIFOLD_CONNECTOR_ENCRYPTION_KEY
    MANIFOLD_EDGE_DATABASE_URL
    MANIFOLD_EDGE_API_URL
    MANIFOLD_EDGE_SHARED_SECRET
    MANIFOLD_EDGE_INSTALLATION_ID
    MANIFOLD_GMAIL_CLIENT_ID
    MANIFOLD_GMAIL_CLIENT_SECRET
    MANIFOLD_GMAIL_AUTHORIZATION_URL
    MANIFOLD_GMAIL_TOKEN_URL
    MANIFOLD_GMAIL_USERINFO_URL
    MANIFOLD_GMAIL_API_BASE_URL
    MANIFOLD_MICROSOFT_CLIENT_ID
    MANIFOLD_MICROSOFT_CLIENT_SECRET
    MANIFOLD_MICROSOFT_TENANT
    MANIFOLD_MICROSOFT_AUTHORIZATION_URL
    MANIFOLD_MICROSOFT_TOKEN_URL
    MANIFOLD_MICROSOFT_API_BASE_URL
    SECRET_KEY_BASE
  )

  setup do
    original_env = Map.new(@runtime_env_vars, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(original_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "development Oban configuration includes connector processing and polling" do
    config = read_config(:dev)
    oban = get_in(config, [:manifold_data, Oban])

    assert oban[:queues][:connectors] == 2

    assert {"*/5 * * * *", Manifold.Connectors.Jobs.PollAccounts} in oban[:plugins][
             Oban.Plugins.Cron
           ][:crontab]
  end

  test "connectors ship in the local release but not the edge release" do
    releases = Manifold.Umbrella.MixProject.project()[:releases]
    local_apps = releases[:manifold][:applications]
    edge_apps = releases[:manifold_edge][:applications]

    assert local_apps[:manifold_connectors] == :permanent
    refute Keyword.has_key?(edge_apps, :manifold_connectors)
  end

  test "inbound SMTP ships only in the edge release" do
    releases = Manifold.Umbrella.MixProject.project()[:releases]
    local_apps = releases[:manifold][:applications]
    edge_apps = releases[:manifold_edge][:applications]

    refute Keyword.has_key?(local_apps, :manifold_smtp)
    assert edge_apps[:manifold_smtp] == :permanent
  end

  test "default runtime disables the inbound SMTP listener" do
    smtp = read_config(:dev)[:manifold_smtp]

    refute smtp[:enabled]
  end

  test "edge runtime enables the inbound SMTP listener" do
    put_runtime_env(%{
      "RELEASE_NAME" => "manifold_edge",
      "MANIFOLD_EDGE_DATABASE_URL" => "ecto://localhost/manifold_edge",
      "MANIFOLD_EDGE_API_URL" => "https://edge.example",
      "MANIFOLD_EDGE_SHARED_SECRET" => String.duplicate("e", 32),
      "MANIFOLD_EDGE_INSTALLATION_ID" => "edge-1"
    })

    smtp = read_runtime(:prod)[:manifold_smtp]

    assert smtp[:enabled]
  end

  test "test connector defaults use a valid non-production key and inert endpoints" do
    connectors = read_config(:test)[:manifold_connectors]

    assert {:ok, key} = Base.decode64(connectors[:encryption_key])
    assert byte_size(key) == 32

    assert connectors[:adapters] == [
             gmail: Manifold.Connectors.Provider.Gmail,
             microsoft: Manifold.Connectors.Provider.MicrosoftGraph,
             imap: Manifold.Connectors.Provider.IMAP,
             eas: Manifold.Connectors.Provider.EAS
           ]

    assert connectors[:providers][:gmail][:base_url] == "https://gmail.invalid"
    assert connectors[:providers][:microsoft][:base_url] == "https://graph.microsoft.invalid/v1.0"
    refute Keyword.has_key?(connectors[:providers][:gmail], :client_id)
    refute Keyword.has_key?(connectors[:providers][:gmail], :client_secret)
    refute Keyword.has_key?(connectors[:providers][:microsoft], :client_id)
    refute Keyword.has_key?(connectors[:providers][:microsoft], :client_secret)
  end

  test "production runtime ignores legacy OAuth credentials and parses endpoint overrides" do
    encryption_key = Base.encode64(:crypto.strong_rand_bytes(32))

    put_runtime_env(%{
      "RELEASE_NAME" => "manifold",
      "MANIFOLD_CONNECTOR_ENCRYPTION_KEY" => encryption_key,
      "MANIFOLD_GMAIL_CLIENT_ID" => "gmail-id",
      "MANIFOLD_GMAIL_CLIENT_SECRET" => "gmail-secret",
      "MANIFOLD_GMAIL_AUTHORIZATION_URL" => "https://accounts.example/authorize",
      "MANIFOLD_GMAIL_TOKEN_URL" => "https://accounts.example/token",
      "MANIFOLD_GMAIL_USERINFO_URL" => "https://openid.example/userinfo",
      "MANIFOLD_GMAIL_API_BASE_URL" => "https://gmail.example",
      "MANIFOLD_MICROSOFT_CLIENT_ID" => "microsoft-id",
      "MANIFOLD_MICROSOFT_CLIENT_SECRET" => "microsoft-secret",
      "MANIFOLD_MICROSOFT_TENANT" => "consumers",
      "MANIFOLD_MICROSOFT_AUTHORIZATION_URL" => "https://login.example/authorize",
      "MANIFOLD_MICROSOFT_TOKEN_URL" => "https://login.example/token",
      "MANIFOLD_MICROSOFT_API_BASE_URL" => "https://graph.example/v1.0",
      "SECRET_KEY_BASE" => String.duplicate("s", 64)
    })

    connectors = read_runtime(:prod)[:manifold_connectors] || []

    assert connectors[:encryption_key] == encryption_key

    assert connectors[:providers][:gmail] == [
             authorization_url: "https://accounts.example/authorize",
             token_url: "https://accounts.example/token",
             userinfo_url: "https://openid.example/userinfo",
             base_url: "https://gmail.example"
           ]

    assert connectors[:providers][:microsoft] == [
             authorization_url: "https://login.example/authorize",
             token_url: "https://login.example/token",
             base_url: "https://graph.example/v1.0",
             tenant: "organizations"
           ]
  end

  test "development runtime ignores all legacy Microsoft credential combinations" do
    for legacy_env <- [
          %{"MANIFOLD_MICROSOFT_CLIENT_ID" => "microsoft-dev-id"},
          %{"MANIFOLD_MICROSOFT_CLIENT_SECRET" => "microsoft-dev-secret"},
          %{
            "MANIFOLD_MICROSOFT_CLIENT_ID" => "microsoft-dev-id",
            "MANIFOLD_MICROSOFT_CLIENT_SECRET" => "microsoft-dev-secret"
          }
        ] do
      put_runtime_env(legacy_env)

      microsoft = read_runtime(:dev)[:manifold_connectors][:providers][:microsoft]

      refute Keyword.has_key?(microsoft, :client_id)
      refute Keyword.has_key?(microsoft, :client_secret)
      assert microsoft[:tenant] == "organizations"
    end
  end

  test "development runtime ignores complete legacy Gmail credentials" do
    put_runtime_env(%{
      "MANIFOLD_GMAIL_CLIENT_ID" => "gmail-dev-id",
      "MANIFOLD_GMAIL_CLIENT_SECRET" => "gmail-dev-secret"
    })

    connectors = read_runtime(:dev)[:manifold_connectors]

    refute Keyword.has_key?(connectors[:providers][:gmail], :client_id)
    refute Keyword.has_key?(connectors[:providers][:gmail], :client_secret)
    refute Keyword.has_key?(connectors, :encryption_key)
  end

  test "development runtime ignores half-configured legacy Gmail credentials" do
    for legacy_env <- [
          %{"MANIFOLD_GMAIL_CLIENT_ID" => "gmail-dev-id"},
          %{"MANIFOLD_GMAIL_CLIENT_SECRET" => "gmail-dev-secret"}
        ] do
      put_runtime_env(legacy_env)

      connectors = read_runtime(:dev)[:manifold_connectors]

      refute Keyword.has_key?(connectors[:providers][:gmail], :client_id)
      refute Keyword.has_key?(connectors[:providers][:gmail], :client_secret)
    end
  end

  test "Gmail endpoint overrides still require absolute HTTPS URLs" do
    put_runtime_env(%{"MANIFOLD_GMAIL_TOKEN_URL" => "http://oauth.example/token"})

    assert_raise RuntimeError, ~r/MANIFOLD_GMAIL_TOKEN_URL must be an absolute https URL/, fn ->
      read_runtime(:dev)
    end
  end

  test "production local release rejects a missing connector encryption key" do
    put_runtime_env(%{
      "RELEASE_NAME" => "manifold",
      "SECRET_KEY_BASE" => String.duplicate("s", 64)
    })

    assert_raise RuntimeError, ~r/MANIFOLD_CONNECTOR_ENCRYPTION_KEY/, fn ->
      read_runtime(:prod)
    end
  end

  test "edge runtime does not require connector configuration" do
    put_runtime_env(%{
      "RELEASE_NAME" => "manifold_edge",
      "MANIFOLD_EDGE_DATABASE_URL" => "ecto://localhost/manifold_edge",
      "MANIFOLD_EDGE_API_URL" => "https://edge.example",
      "MANIFOLD_EDGE_SHARED_SECRET" => String.duplicate("e", 32),
      "MANIFOLD_EDGE_INSTALLATION_ID" => "edge-1"
    })

    connectors = read_runtime(:prod)[:manifold_connectors] || []

    refute Keyword.has_key?(connectors, :encryption_key)
  end

  defp read_config(env) do
    Config.Reader.read!(Path.join(root_path(), "config/config.exs"), env: env)
  end

  defp read_runtime(env) do
    Config.Reader.read!(Path.join(root_path(), "config/runtime.exs"), env: env)
  end

  defp put_runtime_env(values) do
    Enum.each(@runtime_env_vars, &System.delete_env/1)
    Enum.each(values, fn {name, value} -> System.put_env(name, value) end)
  end

  defp root_path, do: Path.expand("../../../../", __DIR__)
end

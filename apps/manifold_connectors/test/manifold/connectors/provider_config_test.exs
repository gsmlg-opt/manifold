defmodule Manifold.Connectors.ProviderConfigTest do
  use Manifold.DataCase, async: false

  alias Manifold.Connectors
  alias Manifold.Connectors.ProviderConfig
  alias Manifold.Connectors.Schema.OAuthProviderSetting
  alias Manifold.Core.Error
  alias Manifold.Repo

  setup do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_providers = Application.get_env(:manifold_connectors, :providers)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:providers, old_providers)
    end)

    :ok
  end

  test "Gmail resolver combines database credentials with trusted endpoints and generation" do
    secret = "db-secret-not-for-inspection"
    setting = put_gmail_setting!("db-client", secret)

    assert {:ok, %ProviderConfig.Resolved{} = resolved} = ProviderConfig.fetch("gmail")

    assert resolved.provider == "gmail"
    assert resolved.setting_id == setting.id
    assert resolved.setting_lock_version == setting.lock_version

    assert Map.new(resolved.config) == %{
             authorization_url: "https://accounts.google.com/o/oauth2/v2/auth",
             token_url: "https://oauth2.googleapis.com/token",
             userinfo_url: "https://openidconnect.googleapis.com/v1/userinfo",
             base_url: "https://gmail.googleapis.com",
             client_id: "db-client",
             client_secret: secret
           }

    refute inspect(resolved) =~ secret
  end

  test "Gmail resolver honors configured endpoint overrides but ignores other application values" do
    secret = "db-secret-not-for-inspection"
    put_gmail_setting!("db-client", secret)

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        client_id: "legacy-client",
        client_secret: "legacy-secret",
        authorization_url: "https://accounts.example/authorize",
        token_url: "https://accounts.example/token",
        userinfo_url: "https://openid.example/userinfo",
        base_url: "https://gmail.example",
        untrusted_extra: "ignored"
      ]
    )

    assert {:ok, %ProviderConfig.Resolved{} = resolved} = ProviderConfig.fetch("gmail")

    assert Map.new(resolved.config) == %{
             authorization_url: "https://accounts.example/authorize",
             token_url: "https://accounts.example/token",
             userinfo_url: "https://openid.example/userinfo",
             base_url: "https://gmail.example",
             client_id: "db-client",
             client_secret: secret
           }

    refute inspect(resolved) =~ secret
    refute inspect(resolved) =~ "legacy-secret"
    refute Keyword.has_key?(resolved.config, :untrusted_extra)
  end

  test "legacy application credentials cannot configure Gmail" do
    secret = "legacy-secret-not-for-errors"

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        client_id: "legacy-client",
        client_secret: secret,
        authorization_url: "https://accounts.google.com/o/oauth2/v2/auth"
      ]
    )

    assert {:error, %Error{class: :permanent, reason: :provider_not_configured} = error} =
             ProviderConfig.fetch("gmail")

    refute inspect(error) =~ secret
    refute inspect(error) =~ "credential"
  end

  test "corrupt Gmail settings return a generic permanent configuration error" do
    secret = "corrupt-secret-not-for-errors"
    setting = put_gmail_setting!("db-client", secret)

    OAuthProviderSetting
    |> where([provider_setting], provider_setting.id == ^setting.id)
    |> Repo.update_all(set: [client_secret_ciphertext: <<1, 2, 3>>])

    assert {:error, %Error{class: :permanent, reason: :provider_configuration_error} = error} =
             ProviderConfig.fetch("gmail")

    inspected = inspect(error)
    refute inspected =~ secret
    refute inspected =~ "credential_authentication_failed"
    refute inspected =~ "invalid_credential_envelope"
    refute inspected =~ "ciphertext"
  end

  test "configured providers reflects Gmail saves and removals immediately" do
    Application.put_env(:manifold_connectors, :providers, [])

    assert Connectors.configured_providers() == []

    setting = put_gmail_setting!("db-client", "db-secret")
    assert Connectors.configured_providers() == ["gmail"]

    assert {:ok, %{status: :not_configured}} =
             Connectors.remove_oauth_provider_setting("gmail",
               expected_lock_version: setting.lock_version
             )

    assert Connectors.configured_providers() == []
  end

  test "Microsoft resolver preserves application configuration without a setting generation" do
    microsoft_config = [
      client_id: "microsoft-client",
      client_secret: "microsoft-secret",
      authorization_url: "https://login.example/authorize",
      token_url: "https://login.example/token",
      base_url: "https://graph.example/v1.0",
      tenant: "tenant-id",
      existing_behavior: :preserved
    ]

    Application.put_env(:manifold_connectors, :providers, microsoft: microsoft_config)

    assert {:ok,
            %ProviderConfig.Resolved{
              provider: "microsoft",
              config: ^microsoft_config,
              setting_id: nil,
              setting_lock_version: nil
            }} = ProviderConfig.fetch("microsoft")

    assert Connectors.configured_providers() == ["microsoft"]
  end

  test "incomplete Microsoft configuration remains not configured" do
    Application.put_env(:manifold_connectors, :providers,
      microsoft: [client_id: "microsoft-client", client_secret: "microsoft-secret"]
    )

    assert {:error, %Error{class: :permanent, reason: :provider_not_configured}} =
             ProviderConfig.fetch("microsoft")

    assert Connectors.configured_providers() == []
  end

  test "unknown providers are rejected without creating atoms" do
    provider = "unsupported-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end

    assert {:error, %Error{class: :permanent, reason: :unsupported_provider}} =
             ProviderConfig.fetch(provider)

    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end
  end

  defp put_gmail_setting!(client_id, client_secret) do
    assert {:ok, _view} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => client_id, "client_secret" => client_secret},
               expected_lock_version: nil
             )

    Repo.get_by!(OAuthProviderSetting, provider: "gmail")
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

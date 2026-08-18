defmodule Manifold.Connectors.Schema.OAuthProviderSettingTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.Schema.{OAuthProviderSetting, OAuthTransaction}

  test "provider setting redacts secret fields" do
    setting = %OAuthProviderSetting{
      id: Ecto.UUID.generate(),
      provider: "gmail",
      client_id: "client-id",
      client_secret: "browser-secret",
      client_secret_ciphertext: <<1, 2, 3>>
    }

    inspected = inspect(setting)
    refute inspected =~ "browser-secret"
    refute inspected =~ inspect(<<1, 2, 3>>)
  end

  test "provider setting trims identifiers and validates persisted fields" do
    changeset =
      OAuthProviderSetting.changeset(%OAuthProviderSetting{}, %{
        provider: "  future-provider  ",
        client_id: "  client-id  ",
        client_secret: "browser-secret",
        client_secret_ciphertext: <<1, 2, 3>>,
        key_version: 2,
        lock_version: 3
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :provider) == "future-provider"
    assert Ecto.Changeset.get_change(changeset, :client_id) == "client-id"
    assert Ecto.Changeset.get_change(changeset, :client_secret) == "browser-secret"
  end

  test "provider setting rejects blank identifiers and non-positive versions" do
    changeset =
      OAuthProviderSetting.changeset(%OAuthProviderSetting{}, %{
        provider: " \t ",
        client_id: "  ",
        client_secret_ciphertext: <<1>>,
        key_version: 0,
        lock_version: -1
      })

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:provider]
    assert {"can't be blank", _} = changeset.errors[:client_id]

    assert {_, [validation: :number, kind: :greater_than, number: 0]} =
             changeset.errors[:key_version]

    assert {_, [validation: :number, kind: :greater_than, number: 0]} =
             changeset.errors[:lock_version]
  end

  test "provider setting declares database uniqueness and presence constraints" do
    constraints =
      OAuthProviderSetting.changeset(%OAuthProviderSetting{}, %{})
      |> Map.fetch!(:constraints)
      |> Enum.map(&to_string(&1.constraint))

    assert "connector_oauth_provider_settings_provider_index" in constraints
    assert "oauth_provider_settings_provider_present" in constraints
    assert "oauth_provider_settings_client_id_present" in constraints
    assert "oauth_provider_settings_key_version_positive" in constraints
    assert "oauth_provider_settings_lock_version_positive" in constraints
  end

  test "OAuth transaction accepts a paired provider-setting generation" do
    setting_id = Ecto.UUID.generate()

    changeset =
      transaction_changeset(%{
        oauth_provider_setting_id: setting_id,
        oauth_provider_setting_lock_version: 2
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_change(changeset, :oauth_provider_setting_id) == setting_id
    assert Ecto.Changeset.get_change(changeset, :oauth_provider_setting_lock_version) == 2
  end

  test "OAuth transaction requires both provider-setting generation fields or neither" do
    assert transaction_changeset(%{}).valid?

    id_only = transaction_changeset(%{oauth_provider_setting_id: Ecto.UUID.generate()})
    refute id_only.valid?

    assert {"must be present with OAuth provider setting", _} =
             id_only.errors[:oauth_provider_setting_lock_version]

    version_only = transaction_changeset(%{oauth_provider_setting_lock_version: 1})
    refute version_only.valid?

    assert {"must be present with OAuth provider setting lock version", _} =
             version_only.errors[:oauth_provider_setting_id]
  end

  test "OAuth transaction validates provider-setting UUID and positive lock version" do
    invalid_id =
      transaction_changeset(%{
        oauth_provider_setting_id: "not-a-uuid",
        oauth_provider_setting_lock_version: 1
      })

    refute invalid_id.valid?
    assert {"is invalid", _} = invalid_id.errors[:oauth_provider_setting_id]

    invalid_version =
      transaction_changeset(%{
        oauth_provider_setting_id: Ecto.UUID.generate(),
        oauth_provider_setting_lock_version: 0
      })

    refute invalid_version.valid?

    assert {_, [validation: :number, kind: :greater_than, number: 0]} =
             invalid_version.errors[:oauth_provider_setting_lock_version]
  end

  defp transaction_changeset(attrs) do
    OAuthTransaction.changeset(
      %OAuthTransaction{},
      Map.merge(
        %{
          state_digest: <<1, 2, 3>>,
          provider: "gmail",
          mailbox_id: Ecto.UUID.generate(),
          purpose: "receive",
          required_scopes: [],
          pkce_verifier_ciphertext: <<4, 5, 6>>,
          redirect_uri: "https://example.test/connectors/gmail/callback",
          expires_at: DateTime.utc_now()
        },
        attrs
      )
    )
  end
end

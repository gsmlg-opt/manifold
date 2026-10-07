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
    assert "oauth_provider_settings_callback_provider_valid" in constraints
  end

  test "Microsoft device setting needs no secret while code settings still do" do
    attrs = %{provider: "microsoft", client_id: "public-client", auth_flow: "device_code"}
    assert OAuthProviderSetting.changeset(%OAuthProviderSetting{}, attrs).valid?

    for rejected <- [
          %{attrs | provider: "gmail"},
          %{attrs | auth_flow: "authorization_code"},
          Map.put(attrs, :client_secret_ciphertext, <<1>>),
          %{attrs | auth_flow: "unknown"}
        ] do
      refute OAuthProviderSetting.changeset(%OAuthProviderSetting{}, rejected).valid?
    end
  end

  test "Gmail callback accepts custom HTTPS paths and HTTP loopback URLs" do
    for url <- [
          "https://mail.example.test/operator/callback?mode=google",
          "http://localhost:4290/custom/callback",
          "http://127.0.0.1:8080/callback",
          "http://127.2.3.4:8080/callback",
          "http://[::1]:8080/callback"
        ] do
      assert callback_changeset(url).valid?
    end

    assert callback_changeset(nil).valid?
    assert callback_changeset("").valid?
  end

  test "Gmail callback rejects malformed or unsafe URLs" do
    for url <- [
          "callback",
          "//localhost/callback",
          "https:///callback",
          "ftp://localhost/callback",
          "http://0.0.0.0/callback",
          "http://192.168.1.1/callback",
          "https://example.test:0/callback",
          "https://example.test:65536/callback",
          "https://example.test/callback#",
          "https://user@example.test/callback",
          "https://exa mple.test/callback",
          "http://localhost.example.test/callback"
        ] do
      changeset = callback_changeset(url)
      refute changeset.valid?, url
      assert changeset.errors[:callback_url], url
    end

    refute callback_changeset("http://localhost/callback", "microsoft").valid?
  end

  test "a saved callback URL can be cleared with nil or a blank value" do
    setting = %OAuthProviderSetting{
      provider: "gmail",
      client_id: "client",
      client_secret_ciphertext: <<1>>,
      callback_url: "http://localhost:4290/callback"
    }

    for value <- [nil, "", "  "] do
      changeset = OAuthProviderSetting.changeset(setting, %{callback_url: value})
      assert changeset.valid?
      assert is_nil(Ecto.Changeset.get_field(changeset, :callback_url))
    end
  end

  defp callback_changeset(url, provider \\ "gmail") do
    OAuthProviderSetting.changeset(%OAuthProviderSetting{}, %{
      provider: provider,
      client_id: "client",
      client_secret_ciphertext: <<1>>,
      callback_url: url
    })
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

  test "OAuth transaction declares provider-setting generation constraints" do
    constraints =
      transaction_changeset(%{
        oauth_provider_setting_id: Ecto.UUID.generate(),
        oauth_provider_setting_lock_version: 1
      })
      |> Map.fetch!(:constraints)
      |> Enum.map(&to_string(&1.constraint))

    assert "oauth_transaction_setting_generation_valid" in constraints
    assert "oauth_transaction_setting_lock_version_positive" in constraints
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

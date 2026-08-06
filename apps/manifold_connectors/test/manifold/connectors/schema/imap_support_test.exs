defmodule Manifold.Connectors.Schema.ImapSupportTest do
  use Manifold.DataCase, async: true

  alias Manifold.Connectors.Schema.{Credential, ReceiveMethod, ImapSettings}

  test "external account accepts imap provider" do
    changeset =
      ReceiveMethod.changeset(%ReceiveMethod{}, %{
        mailbox_id: Ecto.UUID.generate(),
        provider: "imap",
        provider_account_id: "imap:user@example.com",
        email_address: "user@example.com",
        status: "connected",
        sync_enabled: true,
        granted_scopes: []
      })

    assert changeset.valid?
  end

  test "password credentials require password ciphertext and allow nil refresh" do
    changeset =
      Credential.changeset(%Credential{}, %{
        external_account_id: Ecto.UUID.generate(),
        key_version: 1,
        secret_kind: "password",
        password_ciphertext: <<1, 2, 3>>,
        refresh_token_ciphertext: nil
      })

    assert changeset.valid?
  end

  test "oauth credentials still require refresh token" do
    changeset =
      Credential.changeset(%Credential{}, %{
        external_account_id: Ecto.UUID.generate(),
        key_version: 1,
        secret_kind: "oauth",
        refresh_token_ciphertext: nil
      })

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:refresh_token_ciphertext]
  end

  test "imap settings validate tls mode and port" do
    good =
      ImapSettings.changeset(%ImapSettings{}, %{
        external_account_id: Ecto.UUID.generate(),
        host: "imap.example.com",
        port: 993,
        tls_mode: "ssl",
        username: "user@example.com",
        mailbox_path: "INBOX"
      })

    assert good.valid?

    bad =
      ImapSettings.changeset(%ImapSettings{}, %{
        external_account_id: Ecto.UUID.generate(),
        host: "imap.example.com",
        port: 0,
        tls_mode: "plain",
        username: "user@example.com"
      })

    refute bad.valid?
  end
end

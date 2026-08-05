defmodule Manifold.Repo.Migrations.AddImapConnectorSupport do
  use Ecto.Migration

  def up do
    alter table(:connector_credentials) do
      add(:secret_kind, :text, null: false, default: "oauth")
      add(:password_ciphertext, :binary)
      modify(:refresh_token_ciphertext, :binary, null: true, from: {:binary, null: false})
    end

    create(
      constraint(:connector_credentials, :connector_credentials_secret_kind_valid,
        check: "secret_kind IN ('oauth', 'password')"
      )
    )

    create(
      constraint(:connector_credentials, :connector_credentials_oauth_refresh_required,
        check: "secret_kind <> 'oauth' OR refresh_token_ciphertext IS NOT NULL"
      )
    )

    create(
      constraint(:connector_credentials, :connector_credentials_password_required,
        check: "secret_kind <> 'password' OR password_ciphertext IS NOT NULL"
      )
    )

    create table(:connector_imap_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :external_account_id,
        references(:connector_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:host, :text, null: false)
      add(:port, :integer, null: false)
      add(:tls_mode, :text, null: false)
      add(:username, :text, null: false)
      add(:mailbox_path, :text, null: false, default: "INBOX")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:connector_imap_settings, [:external_account_id]))

    create(
      constraint(:connector_imap_settings, :connector_imap_settings_tls_mode_valid,
        check: "tls_mode IN ('ssl', 'starttls')"
      )
    )

    create(
      constraint(:connector_imap_settings, :connector_imap_settings_port_valid,
        check: "port > 0 AND port <= 65535"
      )
    )
  end

  def down do
    drop(table(:connector_imap_settings))

    drop(constraint(:connector_credentials, :connector_credentials_password_required))
    drop(constraint(:connector_credentials, :connector_credentials_oauth_refresh_required))
    drop(constraint(:connector_credentials, :connector_credentials_secret_kind_valid))

    alter table(:connector_credentials) do
      remove(:password_ciphertext)
      remove(:secret_kind)
      modify(:refresh_token_ciphertext, :binary, null: false, from: {:binary, null: true})
    end
  end
end

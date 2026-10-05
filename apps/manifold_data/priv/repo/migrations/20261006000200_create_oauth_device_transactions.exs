defmodule Manifold.Repo.Migrations.CreateOAuthDeviceTransactions do
  use Ecto.Migration

  def up do
    create table(:connector_oauth_device_transactions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:account_id, references(:mailboxes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:purpose, :text, null: false)
      add(:required_scopes, {:array, :text}, null: false)
      add(:oauth_provider_setting_id, :binary_id, null: false)
      add(:oauth_provider_setting_lock_version, :integer, null: false)
      add(:device_code_ciphertext, :binary)
      add(:user_code, :text, null: false)
      add(:verification_uri, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:interval, :integer, null: false)
      add(:next_poll_at, :utc_datetime_usec, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:claim_id, :binary_id)
      add(:claim_expires_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:connector_oauth_device_transactions, [:account_id]))

    create(
      constraint(:connector_oauth_device_transactions, :oauth_device_purpose_valid,
        check: "purpose IN ('receive', 'send')"
      )
    )

    create(
      constraint(:connector_oauth_device_transactions, :oauth_device_status_valid,
        check: "status IN ('pending', 'polling', 'complete', 'cancelled', 'expired', 'failed')"
      )
    )

    create(
      constraint(:connector_oauth_device_transactions, :oauth_device_interval_positive,
        check: "interval > 0 AND oauth_provider_setting_lock_version > 0"
      )
    )
  end

  def down do
    %{rows: [[device_count]]} =
      repo().query!(
        "SELECT COUNT(*) FROM connector_oauth_provider_settings WHERE auth_flow = 'device_code'"
      )

    if device_count > 0 do
      raise Ecto.MigrationError,
            "Cannot remove OAuth device transactions while device-code settings exist; " <>
              "switch Microsoft OAuth settings to authorization code or remove them before rollback"
    end

    drop(table(:connector_oauth_device_transactions))
  end
end

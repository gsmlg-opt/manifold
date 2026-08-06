defmodule Manifold.Repo.Migrations.AddAccountSendMethods do
  use Ecto.Migration

  def up do
    create table(:connector_send_methods, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :mailbox_id,
        references(:mailboxes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:email_address, :text, null: false)
      add(:status, :text, null: false, default: "connected")
      add(:enabled, :boolean, null: false, default: false)
      add(:last_verified_at, :utc_datetime_usec)
      add(:last_error_class, :text)
      add(:last_error_code, :text)
      add(:last_error_message, :text)
      add(:disconnected_at, :utc_datetime_usec)
      add(:lock_version, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:connector_send_methods, [:mailbox_id]))

    create(
      index(:connector_send_methods, [:mailbox_id],
        unique: true,
        where: "enabled = true",
        name: :connector_send_methods_one_enabled_per_mailbox_index
      )
    )

    create(
      constraint(:connector_send_methods, :connector_send_methods_kind_valid,
        check: "kind IN ('smtp')"
      )
    )

    create(
      constraint(:connector_send_methods, :connector_send_methods_status_valid,
        check: "status IN ('connected', 'failed', 'disconnected', 'reconnect_required')"
      )
    )

    create table(:connector_smtp_settings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :send_method_id,
        references(:connector_send_methods, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:host, :text, null: false)
      add(:port, :integer, null: false)
      add(:tls_mode, :text, null: false)
      add(:username, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:connector_smtp_settings, [:send_method_id]))

    create(
      constraint(:connector_smtp_settings, :connector_smtp_settings_tls_mode_valid,
        check: "tls_mode IN ('ssl', 'tls', 'starttls')"
      )
    )

    create(
      constraint(:connector_smtp_settings, :connector_smtp_settings_port_valid,
        check: "port > 0 AND port <= 65535"
      )
    )

    create table(:connector_send_credentials, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :send_method_id,
        references(:connector_send_methods, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:key_version, :integer, null: false, default: 1)
      add(:password_ciphertext, :binary, null: false)
      add(:lock_version, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:connector_send_credentials, [:send_method_id]))
  end

  def down do
    drop(table(:connector_send_credentials))
    drop(table(:connector_smtp_settings))
    drop(table(:connector_send_methods))
  end
end

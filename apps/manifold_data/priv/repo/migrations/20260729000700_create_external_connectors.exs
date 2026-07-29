defmodule Manifold.Repo.Migrations.CreateExternalConnectors do
  use Ecto.Migration

  def up do
    alter table(:inbound_deliveries) do
      add(:source_kind, :text, null: false, default: "smtp")
      add(:storage_domain_id, references(:domains, type: :binary_id, on_delete: :restrict))
      modify(:peer_ip, :text, null: true, from: {:text, null: false})
    end

    execute("""
    UPDATE inbound_deliveries AS delivery
    SET storage_domain_id = mailbox.domain_id
    FROM delivery_recipients AS recipient
    JOIN mailboxes AS mailbox ON mailbox.id = recipient.mailbox_id
    WHERE recipient.inbound_delivery_id = delivery.id
      AND delivery.storage_domain_id IS NULL
    """)

    execute("""
    UPDATE inbound_deliveries AS delivery
    SET source_kind = 'edge_smtp'
    FROM cloud_ingress_identities AS identity
    WHERE identity.inbound_delivery_id = delivery.id
    """)

    alter table(:inbound_deliveries) do
      modify(:storage_domain_id, :binary_id, null: false)
    end

    create(index(:inbound_deliveries, [:source_kind, :received_at]))
    create(index(:inbound_deliveries, [:storage_domain_id]))

    create table(:external_ingress_identities, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:provider, :text, null: false)
      add(:source_id, :text, null: false)
      add(:external_message_id, :text, null: false)

      add(
        :inbound_delivery_id,
        references(:inbound_deliveries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:raw_size, :bigint, null: false)
      add(:raw_sha256, :text, null: false)
      add(:target_sha256, :text, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :external_ingress_identities,
        [:provider, :source_id, :external_message_id],
        name: :external_ingress_identities_source_message_index
      )
    )

    create(unique_index(:external_ingress_identities, [:inbound_delivery_id]))
    create(index(:external_ingress_identities, [:mailbox_id]))

    create table(:connector_accounts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:provider, :text, null: false)
      add(:provider_account_id, :text, null: false)
      add(:email_address, :text, null: false)
      add(:status, :text, null: false, default: "connected")
      add(:sync_enabled, :boolean, null: false, default: true)
      add(:granted_scopes, {:array, :text}, null: false, default: [])
      add(:last_attempted_at, :utc_datetime_usec)
      add(:last_synced_at, :utc_datetime_usec)
      add(:last_error_class, :text)
      add(:last_error_code, :text)
      add(:last_error_message, :text)
      add(:disconnected_at, :utc_datetime_usec)
      add(:lock_version, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:connector_accounts, [:provider, :provider_account_id],
        name: :connector_accounts_provider_account_index
      )
    )

    create(index(:connector_accounts, [:mailbox_id]))
    create(index(:connector_accounts, [:status, :sync_enabled]))

    create table(:connector_credentials, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :external_account_id,
        references(:connector_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:key_version, :integer, null: false, default: 1)
      add(:access_token_ciphertext, :binary)
      add(:refresh_token_ciphertext, :binary, null: false)
      add(:token_expires_at, :utc_datetime_usec)
      add(:lock_version, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:connector_credentials, [:external_account_id]))

    create table(:connector_oauth_transactions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:state_digest, :binary, null: false)
      add(:provider, :text, null: false)

      add(:mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:pkce_verifier_ciphertext, :binary, null: false)
      add(:redirect_uri, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:consumed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:connector_oauth_transactions, [:state_digest]))
    create(index(:connector_oauth_transactions, [:expires_at]))

    create table(:connector_sync_cursors, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :external_account_id,
        references(:connector_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:scope, :text, null: false)
      add(:phase, :text, null: false, default: "bootstrap")
      add(:bootstrap_cursor, :text)
      add(:page_cursor, :text)
      add(:committed_cursor, :text)
      add(:metadata, :map, null: false, default: %{})
      add(:generation, :integer, null: false, default: 1)
      add(:last_completed_at, :utc_datetime_usec)
      add(:lock_version, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:connector_sync_cursors, [:external_account_id, :scope],
        name: :connector_sync_cursors_account_scope_index
      )
    )

    create table(:connector_remote_messages, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :external_account_id,
        references(:connector_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:provider_message_id, :text, null: false)
      add(:provider_thread_id, :text)

      add(
        :inbound_delivery_id,
        references(:inbound_deliveries, type: :binary_id, on_delete: :restrict)
      )

      add(:provider_received_at, :utc_datetime_usec)
      add(:remote_folder_id, :text)
      add(:remote_folder_kind, :text)
      add(:remote_labels, {:array, :text}, null: false, default: [])
      add(:remote_read, :boolean, null: false, default: false)
      add(:remote_starred, :boolean, null: false, default: false)
      add(:remote_deleted, :boolean, null: false, default: false)
      add(:state, :text, null: false, default: "pending")
      add(:last_error_class, :text)
      add(:last_error_code, :text)
      add(:last_error_message, :text)
      add(:synced_at, :utc_datetime_usec)
      add(:lock_version, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:connector_remote_messages, [:external_account_id, :provider_message_id],
        name: :connector_remote_messages_account_message_index
      )
    )

    create(index(:connector_remote_messages, [:inbound_delivery_id]))
    create(index(:connector_remote_messages, [:external_account_id, :state]))

    create table(:connector_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :external_account_id,
        references(:connector_accounts, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:event_type, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:occurred_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:connector_events, [:external_account_id, :occurred_at]))
  end

  def down do
    raise """
    create_external_connectors is irreversible after provider imports because
    provider deliveries intentionally have no SMTP peer_ip to restore
    """
  end
end

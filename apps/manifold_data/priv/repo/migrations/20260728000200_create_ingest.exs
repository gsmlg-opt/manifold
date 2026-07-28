defmodule Manifold.Repo.Migrations.CreateIngest do
  use Ecto.Migration

  def change do
    create table(:inbound_deliveries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:ingest_id, :text, null: false)
      add(:peer_ip, :text, null: false)
      add(:helo, :text)
      add(:envelope_from, :text)
      add(:received_at, :utc_datetime_usec, null: false)
      add(:raw_size, :bigint, null: false)
      add(:raw_sha256, :text, null: false)
      add(:spool_bundle_path, :text, null: false)
      add(:raw_object_key, :text)
      add(:raw_storage_state, :text, null: false, default: "spooled")
      add(:processing_state, :text, null: false, default: "accepted")
      add(:last_error, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:inbound_deliveries, [:ingest_id]))
    create(index(:inbound_deliveries, [:raw_storage_state]))
    create(index(:inbound_deliveries, [:processing_state]))

    create table(:delivery_recipients, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :inbound_delivery_id,
        references(:inbound_deliveries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:original_address, :text, null: false)
      add(:canonical_address, :text, null: false)
      add(:plus_tag, :text)

      add(:mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :restrict),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:delivery_recipients, [:inbound_delivery_id]))
    create(index(:delivery_recipients, [:mailbox_id]))

    create table(:mailbox_entries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(
        :inbound_delivery_id,
        references(:inbound_deliveries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:original_recipient, :text, null: false)
      add(:status, :text, null: false, default: "unread")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:mailbox_entries, [:mailbox_id, :inbound_delivery_id]))
    create(index(:mailbox_entries, [:inbound_delivery_id]))

    create table(:message_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :inbound_delivery_id,
        references(:inbound_deliveries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:event_type, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:occurred_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:message_events, [:inbound_delivery_id, :occurred_at]))
  end
end

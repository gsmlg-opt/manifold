defmodule Manifold.Repo.Migrations.CreateAccountPurgeLifecycle do
  use Ecto.Migration

  def change do
    alter table(:mailboxes) do
      add(:purge_requested_at, :utc_datetime_usec)
    end

    create(index(:mailboxes, [:purge_requested_at], where: "purge_requested_at IS NOT NULL"))

    create table(:account_purges, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:mailbox_id, :binary_id, null: false)
      add(:status, :text, null: false, default: "requested")
      add(:stage, :text, null: false, default: "discover")
      add(:progress, :map, null: false, default: %{})
      add(:error_class, :text)
      add(:error_code, :text)
      add(:error_message, :text)
      add(:discovered_deliveries, :integer, null: false, default: 0)
      add(:purged_deliveries, :integer, null: false, default: 0)
      add(:shared_retained_deliveries, :integer, null: false, default: 0)
      add(:deleted_objects, :integer, null: false, default: 0)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:account_purges, [:mailbox_id]))

    create(
      constraint(:account_purges, :account_purges_status_valid,
        check: "status IN ('requested', 'running', 'failed', 'completed')"
      )
    )

    create(
      constraint(:account_purges, :account_purges_stage_valid,
        check:
          "stage IN ('discover', 'drain', 'connectors', 'outbound', 'mailbox_copy', 'orphan_payloads', 'objects', 'finalize', 'completed')"
      )
    )

    create(
      constraint(:account_purges, :account_purges_counters_nonnegative,
        check:
          "discovered_deliveries >= 0 AND purged_deliveries >= 0 AND shared_retained_deliveries >= 0 AND deleted_objects >= 0"
      )
    )

    create table(:account_purge_deliveries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:purge_id, references(:account_purges, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:inbound_delivery_id, :binary_id, null: false)
      add(:disposition, :text, null: false, default: "pending")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:account_purge_deliveries, [:purge_id, :inbound_delivery_id]))

    create(
      constraint(:account_purge_deliveries, :account_purge_deliveries_disposition_valid,
        check: "disposition IN ('pending', 'shared_retained', 'purged')"
      )
    )

    create table(:account_purge_objects, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:purge_id, references(:account_purges, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:object_key, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:attempts, :integer, null: false, default: 0)
      add(:last_error, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:account_purge_objects, [:purge_id, :kind, :object_key]))

    create(
      constraint(:account_purge_objects, :account_purge_objects_kind_valid,
        check: "kind IN ('raw', 'blob', 'spool', 'activity_log')"
      )
    )

    create(
      constraint(:account_purge_objects, :account_purge_objects_status_valid,
        check: "status IN ('pending', 'completed')"
      )
    )

    create(
      constraint(:account_purge_objects, :account_purge_objects_attempts_nonnegative,
        check: "attempts >= 0"
      )
    )
  end
end

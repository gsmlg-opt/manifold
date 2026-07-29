defmodule Manifold.Edge.Repo.Migrations.CreateEdgePersistence do
  use Ecto.Migration

  def change do
    create table(:edge_route_snapshots, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:schema_version, :integer, null: false)
      add(:revision, :bigint, null: false)
      add(:digest, :text, null: false)
      add(:generated_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:installed_at, :utc_datetime_usec, null: false)
      add(:active, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:edge_route_snapshots, [:revision]))

    create(
      unique_index(:edge_route_snapshots, [:active],
        where: "active",
        name: :edge_route_snapshots_one_active_index
      )
    )

    create(
      constraint(:edge_route_snapshots, :edge_route_snapshots_schema_version_positive,
        check: "schema_version > 0"
      )
    )

    create(
      constraint(:edge_route_snapshots, :edge_route_snapshots_revision_nonnegative,
        check: "revision >= 0"
      )
    )

    create(
      constraint(:edge_route_snapshots, :edge_route_snapshots_digest_valid,
        check: "digest ~ '^[0-9a-f]{64}$'"
      )
    )

    create(
      constraint(:edge_route_snapshots, :edge_route_snapshots_expiry_valid,
        check: "expires_at > generated_at"
      )
    )

    create table(:edge_routes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :route_snapshot_id,
        references(:edge_route_snapshots, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:position, :integer, null: false)
      add(:canonical_address, :text, null: false)
      add(:domain_id, :text, null: false)
      add(:mailbox_ids, {:array, :text}, null: false)
      add(:plus_addressing_enabled, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:edge_routes, [:route_snapshot_id, :canonical_address]))
    create(unique_index(:edge_routes, [:route_snapshot_id, :position]))
    create(index(:edge_routes, [:route_snapshot_id]))

    create(constraint(:edge_routes, :edge_routes_position_nonnegative, check: "position >= 0"))

    create(
      constraint(:edge_routes, :edge_routes_mailbox_ids_present,
        check: "cardinality(mailbox_ids) > 0"
      )
    )

    create table(:edge_deliveries, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:ingest_id, :text, null: false)

      add(
        :route_snapshot_id,
        references(:edge_route_snapshots, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:snapshot_revision, :bigint, null: false)
      add(:peer_ip, :text, null: false)
      add(:helo, :text)
      add(:envelope_from, :text)
      add(:received_at, :utc_datetime_usec, null: false)
      add(:raw_size, :bigint, null: false)
      add(:raw_sha256, :text, null: false)
      add(:spool_bundle_path, :text, null: false)
      add(:state, :text, null: false, default: "ready")
      add(:local_delivery_id, :binary_id)
      add(:acknowledged_at, :utc_datetime_usec)
      add(:last_error, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:edge_deliveries, [:ingest_id]))
    create(index(:edge_deliveries, [:state, :received_at, :id]))
    create(index(:edge_deliveries, [:route_snapshot_id]))

    create(
      constraint(:edge_deliveries, :edge_deliveries_snapshot_revision_nonnegative,
        check: "snapshot_revision >= 0"
      )
    )

    create(
      constraint(:edge_deliveries, :edge_deliveries_raw_size_nonnegative, check: "raw_size >= 0")
    )

    create(
      constraint(:edge_deliveries, :edge_deliveries_raw_sha256_valid,
        check: "raw_sha256 ~ '^[0-9a-f]{64}$'"
      )
    )

    create(
      constraint(:edge_deliveries, :edge_deliveries_state_valid,
        check: "state IN ('ready', 'acknowledged', 'failed')"
      )
    )

    create(
      constraint(:edge_deliveries, :edge_deliveries_acknowledgement_consistent,
        check:
          "(state = 'acknowledged' AND local_delivery_id IS NOT NULL AND acknowledged_at IS NOT NULL) OR " <>
            "(state <> 'acknowledged' AND local_delivery_id IS NULL AND acknowledged_at IS NULL)"
      )
    )

    create table(:edge_delivery_recipients, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :delivery_id,
        references(:edge_deliveries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:position, :integer, null: false)
      add(:original_address, :text, null: false)
      add(:canonical_address, :text, null: false)
      add(:plus_tag, :text)
      add(:domain_id, :text, null: false)
      add(:mailbox_ids, {:array, :text}, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:edge_delivery_recipients, [:delivery_id, :position]))
    create(index(:edge_delivery_recipients, [:delivery_id]))

    create(
      constraint(:edge_delivery_recipients, :edge_delivery_recipients_position_nonnegative,
        check: "position >= 0"
      )
    )

    create(
      constraint(:edge_delivery_recipients, :edge_delivery_recipients_mailbox_ids_present,
        check: "cardinality(mailbox_ids) > 0"
      )
    )

    create table(:edge_delivery_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :delivery_id,
        references(:edge_deliveries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:event_type, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:occurred_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:edge_delivery_events, [:delivery_id, :occurred_at]))

    create table(:edge_signature_nonces, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:key_id, :text, null: false)
      add(:nonce_digest, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:claimed_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:edge_signature_nonces, [:key_id, :nonce_digest]))
    create(index(:edge_signature_nonces, [:expires_at]))
  end
end

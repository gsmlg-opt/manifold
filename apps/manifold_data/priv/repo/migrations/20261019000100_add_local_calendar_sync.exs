defmodule Manifold.Repo.Migrations.AddLocalCalendarSync do
  use Ecto.Migration

  def up do
    alter table(:calendars) do
      add(:deleted_at, :utc_datetime_usec)
      add(:viewing_timezone, :text, null: false, default: "Etc/UTC")
    end

    alter table(:calendar_events) do
      add(:series_id, :binary_id)
      add(:time_kind, :text, null: false, default: "floating")
      add(:read_only, :boolean, null: false, default: false)
      add(:recurrence_dates, {:array, :text}, null: false, default: [])
      add(:recurrence_timezone, :text)
    end

    create(index(:calendar_events, [:calendar_id, :series_id]))

    create table(:calendar_connections, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:provider, :text, null: false)
      add(:remote_identity, :text)
      add(:identity_verified_at, :utc_datetime_usec)
      add(:display_name, :text)
      add(:credential_context, :text)
      add(:encrypted_credentials, :binary)
      add(:scopes, {:array, :text}, null: false, default: [])
      add(:expires_at, :utc_datetime_usec)
      add(:status, :text, null: false, default: "paused")
      add(:generation, :integer, null: false, default: 1)
      add(:legacy_connection_id, :binary_id)
      add(:provider_metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_connections, [:provider, :remote_identity]))
    create(unique_index(:calendar_connections, [:legacy_connection_id]))

    create table(:calendar_bindings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:calendar_id, references(:calendars, type: :binary_id, on_delete: :nilify_all))

      add(
        :connection_id,
        references(:calendar_connections, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:remote_calendar_id, :text, null: false)
      add(:name, :text)
      add(:direction, :text, null: false, default: "bidirectional")
      add(:capabilities, :map, null: false, default: %{})
      add(:state, :text, null: false, default: "preview")
      add(:generation, :integer, null: false, default: 1)
      add(:checkpoint, :map, null: false, default: %{})
      add(:enrollment_manifest, :map, null: false, default: %{})
      add(:lease_owner, :binary_id)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:suppressed_at, :utc_datetime_usec)
      add(:legacy_collection_id, :binary_id)
      add(:last_error, :text)
      add(:synced_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_bindings, [:connection_id, :remote_calendar_id]))
    create(unique_index(:calendar_bindings, [:legacy_collection_id]))
    create(index(:calendar_bindings, [:calendar_id, :state]))

    create table(:calendar_sync_resources, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:binding_id, references(:calendar_bindings, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:remote_resource_id, :text, null: false)
      add(:href, :text)
      add(:base_raw, :text)
      add(:etag, :text)
      add(:remote_raw, :text)
      add(:remote_etag, :text)
      add(:remote_presence, :text, null: false, default: "unknown")
      add(:status, :text, null: false, default: "pending")
      add(:provider_metadata, :map, null: false, default: %{})
      add(:retry_at, :utc_datetime_usec)
      add(:last_error, :text)
      add(:legacy_resource_id, :binary_id)
      add(:legacy_snapshot, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_sync_resources, [:binding_id, :remote_resource_id]))
    create(unique_index(:calendar_sync_resources, [:legacy_resource_id]))

    create table(:calendar_event_bindings, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:binding_id, references(:calendar_bindings, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:event_id, references(:calendar_events, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(
        :resource_id,
        references(:calendar_sync_resources, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:remote_component_key, :text, null: false)
      add(:desired_revision, :bigint, null: false, default: 0)
      add(:acknowledged_revision, :bigint, null: false, default: 0)
      add(:base_projection, :map, null: false, default: %{})
      add(:projection_fields, {:array, :text}, null: false, default: [])
      add(:projection_version, :integer, null: false, default: 1)
      add(:conflict, :map)
      add(:state, :text, null: false, default: "enrolled")
      add(:last_error, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendar_event_bindings, [:binding_id, :event_id]))
    create(unique_index(:calendar_event_bindings, [:resource_id, :remote_component_key]))

    create(
      constraint(:calendar_event_bindings, :calendar_event_binding_revisions_valid,
        check: "acknowledged_revision >= 0 AND desired_revision >= acknowledged_revision"
      )
    )

    create table(:calendar_sync_attempts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :resource_id,
        references(:calendar_sync_resources, type: :binary_id, on_delete: :restrict),
        null: false
      )

      add(:connection_generation, :integer)
      add(:binding_generation, :integer)
      add(:operation, :text, null: false)
      add(:destination, :text, null: false)
      add(:payload, :text)
      add(:precondition, :map, null: false, default: %{})
      add(:component_revisions, :map, null: false, default: %{})
      add(:sent_projections, :map, null: false, default: %{})
      add(:state, :text, null: false, default: "prepared")
      add(:response_etag, :text)
      add(:response_raw, :text)
      add(:last_error, :text)
      add(:dispatched_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      add(:legacy_snapshot, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:calendar_sync_attempts, [:resource_id],
        name: :calendar_sync_attempts_unresolved_index,
        where: "state IN ('prepared', 'dispatched', 'uncertain')"
      )
    )

    # Requests are evidence. Only their result may change after insertion.
    execute("""
    CREATE FUNCTION calendar_attempt_immutable() RETURNS trigger AS $$
    BEGIN
      IF ROW(OLD.resource_id, OLD.connection_generation, OLD.binding_generation,
        OLD.operation, OLD.destination, OLD.payload, OLD.precondition,
        OLD.component_revisions, OLD.sent_projections, OLD.legacy_snapshot)
        IS DISTINCT FROM ROW(NEW.resource_id, NEW.connection_generation, NEW.binding_generation,
        NEW.operation, NEW.destination, NEW.payload, NEW.precondition,
        NEW.component_revisions, NEW.sent_projections, NEW.legacy_snapshot) THEN
        RAISE EXCEPTION 'calendar synchronization request is immutable';
      END IF;
      RETURN NEW;
    END; $$ LANGUAGE plpgsql;
    """)

    execute("""
    CREATE TRIGGER calendar_attempt_immutable BEFORE UPDATE ON calendar_sync_attempts
    FOR EACH ROW EXECUTE FUNCTION calendar_attempt_immutable();
    """)

    flush()
    backfill()
  end

  defp backfill do
    # Preserve the original ciphertext and authenticated context independently of mailboxes.
    # Apple identity must be verified by authenticated discovery before activation.
    execute("""
    INSERT INTO calendar_connections (id, provider, display_name, encrypted_credentials,
      credential_context, status, generation, legacy_connection_id, provider_metadata, inserted_at, updated_at)
    SELECT gen_random_uuid(), 'icloud', apple_id, password_ciphertext,
      'icloud:' || id::text || ':app_password', 'paused', generation, id,
      jsonb_build_object('legacy_credential_format', 'password', 'identity_verification_required', true),
      inserted_at, updated_at FROM icloud_connections
    """)

    execute("""
    INSERT INTO calendar_bindings (id, calendar_id, connection_id, remote_calendar_id, name,
      direction, capabilities, state, checkpoint, enrollment_manifest, legacy_collection_id, inserted_at, updated_at)
    SELECT gen_random_uuid(), c.id, n.id, d.href, d.name,
      CASE WHEN d.writable THEN 'bidirectional' ELSE 'inbound' END,
      jsonb_build_object('create', coalesce(d.can_create, d.writable),
        'update', coalesce(d.can_update, d.writable), 'delete', coalesce(d.can_delete, d.writable)),
      'paused', jsonb_build_object('sync_token', d.sync_token),
      jsonb_build_object('legacy', true, 'confirmed', true, 'identity_verification_required', true),
      d.id, d.inserted_at, d.updated_at
    FROM dav_collections d JOIN calendar_connections n ON n.legacy_connection_id = d.connection_id
    LEFT JOIN calendars c ON c.collection_id = d.id WHERE d.kind = 'calendars'
    """)

    execute("""
    INSERT INTO calendar_sync_resources (id, binding_id, remote_resource_id, href, base_raw,
      etag, remote_raw, remote_etag, remote_presence, status, retry_at, last_error,
      legacy_resource_id, legacy_snapshot, inserted_at, updated_at)
    SELECT gen_random_uuid(), b.id, r.href, r.href, r.base_raw, r.etag, r.remote_raw,
      r.remote_etag, 'unknown',
      CASE WHEN r.sent_revision IS NOT NULL THEN 'uncertain'
        WHEN r.status = 'paused' THEN 'pending' ELSE r.status END,
      r.retry_at, r.last_error, r.id, to_jsonb(r), r.inserted_at, r.updated_at
    FROM dav_resources r JOIN calendar_bindings b ON b.legacy_collection_id = r.collection_id
    WHERE r.kind = 'calendars'
    """)

    # Existing resource identity is proven grouping. Never group unrelated UIDs.
    execute("""
    UPDATE calendar_events e SET series_id = g.series_id FROM (
      SELECT resource_id, uid, gen_random_uuid() AS series_id FROM calendar_events
      WHERE resource_id IS NOT NULL GROUP BY resource_id, uid
    ) g WHERE e.resource_id = g.resource_id AND e.uid = g.uid
    """)

    execute("""
    UPDATE calendar_events SET series_id = gen_random_uuid() WHERE series_id IS NULL
    """)

    execute("""
    UPDATE calendar_events SET time_kind = CASE WHEN all_day THEN 'date'
      WHEN right(starts_at, 1) = 'Z' THEN 'utc'
      WHEN timezone IS NOT NULL THEN 'tzid' ELSE 'floating' END,
      recurrence_timezone = timezone
    """)

    # A resource counter cannot certify component revisions. Start unacknowledged;
    # the application backfill decodes the preserved baseline before writes.
    execute("""
    INSERT INTO calendar_event_bindings (id, binding_id, event_id, resource_id,
      remote_component_key, desired_revision, acknowledged_revision, state, conflict, inserted_at, updated_at)
    SELECT gen_random_uuid(), r.binding_id, e.id, r.id, e.uid || chr(31) || coalesce(e.recurrence_id, ''),
      e.local_revision, 0, 'enrolled',
      CASE WHEN r.status = 'conflict' THEN jsonb_build_object('legacy', true,
        'base_raw', r.base_raw, 'remote_raw', r.remote_raw, 'remote_etag', r.remote_etag) ELSE NULL END,
      e.inserted_at, e.updated_at
    FROM calendar_events e JOIN calendar_sync_resources r ON r.legacy_resource_id = e.resource_id
    """)

    execute("""
    INSERT INTO calendar_sync_attempts (id, resource_id, connection_generation, binding_generation,
      operation, destination, payload, precondition, component_revisions, sent_projections,
      state, legacy_snapshot, inserted_at, updated_at)
    SELECT gen_random_uuid(), n.id, r.sent_generation, b.generation, r.sent_operation,
      r.href, r.sent_raw, jsonb_build_object('etag', r.sent_etag), '{}', '{}', 'uncertain',
      to_jsonb(r), r.updated_at, r.updated_at
    FROM dav_resources r JOIN calendar_sync_resources n ON n.legacy_resource_id = r.id
    JOIN calendar_bindings b ON b.id = n.binding_id WHERE r.sent_revision IS NOT NULL
    """)
  end

  def down do
    raise "Calendar synchronization history must be retained; use the documented reconciled restore procedure"
  end
end

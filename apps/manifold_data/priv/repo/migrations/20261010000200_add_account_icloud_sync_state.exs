defmodule Manifold.Repo.Migrations.AddAccountICloudSyncState do
  use Ecto.Migration

  def up do
    alter table(:icloud_connections) do
      add(:account_id, references(:mailboxes, type: :binary_id, on_delete: :nilify_all))

      add(
        :default_contacts_collection_id,
        references(:dav_collections, type: :binary_id, on_delete: :nilify_all)
      )
    end

    create(unique_index(:icloud_connections, [:account_id]))

    alter table(:dav_collections) do
      add(:writable, :boolean, null: false, default: false)
      add(:can_create, :boolean)
      add(:can_update, :boolean)
      add(:can_delete, :boolean)
      add(:supported_components, {:array, :text}, null: false, default: [])
      add(:privileges, {:array, :text}, null: false, default: [])
    end

    create table(:dav_resources, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:kind, :text, null: false)
      add(:account_id, references(:mailboxes, type: :binary_id, on_delete: :nilify_all))

      add(
        :connection_id,
        references(:icloud_connections, type: :binary_id, on_delete: :nilify_all)
      )

      add(:collection_id, references(:dav_collections, type: :binary_id, on_delete: :nilify_all))
      add(:href, :text, null: false)
      add(:uid, :text, null: false)
      add(:base_raw, :text)
      add(:etag, :text)
      add(:desired_revision, :bigint, null: false, default: 0)
      add(:acknowledged_revision, :bigint, null: false, default: 0)
      add(:status, :text, null: false, default: "pending")
      add(:operation, :text, null: false, default: "upsert")
      add(:sent_revision, :bigint)
      add(:sent_operation, :text)
      add(:sent_generation, :integer)
      add(:sent_raw, :text)
      add(:sent_contact_values, :map)
      add(:sent_etag, :text)
      add(:remote_raw, :text)
      add(:remote_etag, :text)
      add(:last_error, :text)
      add(:retry_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:dav_resources, [:collection_id, :href]))
    create(index(:dav_resources, [:status, :retry_at]))
    create(index(:dav_resources, [:account_id, :connection_id]))

    create(
      constraint(:dav_resources, :dav_resources_status_valid,
        check: "status IN ('pending', 'synced', 'paused', 'conflict', 'uncertain', 'failed')"
      )
    )

    create(
      constraint(:dav_resources, :dav_resources_operation_valid,
        check: "operation IN ('upsert', 'delete')"
      )
    )

    create(
      constraint(:dav_resources, :dav_resources_revisions_valid,
        check: "acknowledged_revision >= 0 AND desired_revision >= acknowledged_revision"
      )
    )

    create table(:calendars, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:account_id, references(:mailboxes, type: :binary_id, on_delete: :nilify_all))
      add(:collection_id, references(:dav_collections, type: :binary_id, on_delete: :nilify_all))
      add(:name, :text, null: false)
      add(:sync_to_icloud, :boolean, null: false, default: true)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:calendars, [:collection_id]))
    create(index(:calendars, [:account_id]))

    # Retained local records must survive remote collection/connection deletion.
    drop(constraint(:contacts, :contacts_collection_id_fkey))
    drop(constraint(:contacts, :contacts_source_identity_valid))

    alter table(:contacts) do
      modify(
        :collection_id,
        references(:dav_collections, type: :binary_id, on_delete: :nilify_all)
      )

      add(:account_id, references(:mailboxes, type: :binary_id, on_delete: :nilify_all))
      add(:sync_to_icloud, :boolean, null: false, default: true)
      add(:local_revision, :bigint, null: false, default: 0)
      add(:deleted_at, :utc_datetime_usec)
      add(:resource_id, references(:dav_resources, type: :binary_id, on_delete: :nilify_all))
    end

    create(unique_index(:contacts, [:resource_id]))
    create(index(:contacts, [:account_id, :deleted_at]))

    create(
      constraint(:contacts, :contacts_source_identity_valid,
        check: "resource_href IS NULL OR length(btrim(resource_href)) > 0"
      )
    )

    drop(constraint(:calendar_events, :calendar_events_collection_id_fkey))

    alter table(:calendar_events) do
      modify(
        :collection_id,
        references(:dav_collections, type: :binary_id, on_delete: :nilify_all),
        null: true
      )

      modify(:resource_href, :text, null: true)
      add(:calendar_id, references(:calendars, type: :binary_id, on_delete: :nilify_all))
      add(:resource_id, references(:dav_resources, type: :binary_id, on_delete: :nilify_all))
      add(:local_revision, :bigint, null: false, default: 0)
      add(:deleted_at, :utc_datetime_usec)
    end

    create(index(:calendar_events, [:calendar_id, :deleted_at]))
    create(index(:calendar_events, [:resource_id]))

    execute("""
    INSERT INTO calendars (id, collection_id, name, inserted_at, updated_at)
    SELECT gen_random_uuid(), id, coalesce(nullif(name, ''), href), inserted_at, updated_at
    FROM dav_collections WHERE kind = 'calendars'
    """)

    execute("""
    INSERT INTO dav_resources (id, kind, connection_id, collection_id, href, uid,
      base_raw, etag, remote_raw, remote_etag, status, inserted_at, updated_at)
    SELECT gen_random_uuid(), 'contacts', d.connection_id, c.collection_id,
      c.resource_href, coalesce(nullif(c.uid, ''), c.id::text), c.raw, c.etag,
      c.raw, c.etag, 'paused', c.inserted_at, c.updated_at
    FROM contacts c JOIN dav_collections d ON d.id = c.collection_id
    """)

    execute("""
    INSERT INTO dav_resources (id, kind, connection_id, collection_id, href, uid,
      base_raw, etag, remote_raw, remote_etag, status, inserted_at, updated_at)
    SELECT gen_random_uuid(), 'calendars', connection_id, collection_id,
      resource_href, uid, raw, etag, raw, etag, 'paused', inserted_at, updated_at
    FROM (
      SELECT DISTINCT ON (e.collection_id, e.resource_href) e.*, d.connection_id
      FROM calendar_events e JOIN dav_collections d ON d.id = e.collection_id
      ORDER BY e.collection_id, e.resource_href, e.recurrence_id, e.id
    ) imported
    """)

    execute("""
    UPDATE contacts c SET resource_id = r.id FROM dav_resources r
    WHERE r.kind = 'contacts' AND c.collection_id = r.collection_id AND c.resource_href = r.href
    """)

    execute("""
    UPDATE calendar_events e SET resource_id = r.id, calendar_id = c.id
    FROM dav_resources r JOIN calendars c ON c.collection_id = r.collection_id
    WHERE r.kind = 'calendars' AND e.collection_id = r.collection_id AND e.resource_href = r.href
    """)
  end

  def down do
    raise "Bidirectional iCloud state contains retained local data; restore a database backup to roll back"
  end
end

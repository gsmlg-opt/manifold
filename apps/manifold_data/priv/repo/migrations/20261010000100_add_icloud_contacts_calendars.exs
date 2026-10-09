defmodule Manifold.Repo.Migrations.AddICloudContactsCalendars do
  use Ecto.Migration

  def change do
    create table(:icloud_connections, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:apple_id, :text, null: false)
      add(:password_ciphertext, :binary, null: false)
      add(:enabled, :boolean, null: false, default: true)
      add(:contacts_enabled, :boolean, null: false, default: true)
      add(:calendars_enabled, :boolean, null: false, default: true)
      add(:generation, :integer, null: false, default: 1)
      add(:contacts_status, :text, null: false, default: "pending")
      add(:contacts_error, :text)
      add(:contacts_synced_at, :utc_datetime_usec)
      add(:calendars_status, :text, null: false, default: "pending")
      add(:calendars_error, :text)
      add(:calendars_synced_at, :utc_datetime_usec)
      add(:next_sync_at, :utc_datetime_usec)
      add(:sync_owner, :binary_id)
      add(:sync_expires_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:icloud_connections, [:enabled, :next_sync_at]))

    create(
      constraint(:icloud_connections, :icloud_connections_apple_id_present,
        check: "length(btrim(apple_id)) > 0"
      )
    )

    create(
      constraint(:icloud_connections, :icloud_connections_generation_positive,
        check: "generation > 0"
      )
    )

    for service <- [:contacts, :calendars] do
      create(
        constraint(:icloud_connections, "icloud_connections_#{service}_status_valid",
          check:
            "#{service}_status IN ('pending', 'syncing', 'connected', 'failed', 'reconnect_required', 'disabled')"
        )
      )
    end

    create table(:dav_collections, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :connection_id,
        references(:icloud_connections, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:kind, :text, null: false)
      add(:href, :text, null: false)
      add(:name, :text)
      add(:sync_token, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:dav_collections, [:connection_id, :kind, :href]))

    create(
      constraint(:dav_collections, :dav_collections_kind_valid,
        check: "kind IN ('contacts', 'calendars')"
      )
    )

    create(
      constraint(:dav_collections, :dav_collections_href_present,
        check: "length(btrim(href)) > 0"
      )
    )

    create table(:contacts, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:collection_id, references(:dav_collections, type: :binary_id, on_delete: :delete_all))
      add(:resource_href, :text)
      add(:uid, :text)
      add(:etag, :text)
      add(:raw, :text)
      add(:full_name, :text, null: false)
      add(:given_name, :text)
      add(:family_name, :text)
      add(:organization, :text)
      add(:notes, :text)
      add(:emails, {:array, :map}, null: false, default: [])
      add(:phones, {:array, :map}, null: false, default: [])
      add(:addresses, {:array, :map}, null: false, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:contacts, [:collection_id, :resource_href]))
    create(index(:contacts, [:full_name, :id]))

    create(
      constraint(:contacts, :contacts_full_name_present, check: "length(btrim(full_name)) > 0")
    )

    create(
      constraint(:contacts, :contacts_source_identity_valid,
        check:
          "(collection_id IS NULL AND resource_href IS NULL) OR (collection_id IS NOT NULL AND resource_href IS NOT NULL AND length(btrim(resource_href)) > 0)"
      )
    )

    create table(:calendar_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:collection_id, references(:dav_collections, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:resource_href, :text, null: false)
      add(:uid, :text, null: false)
      add(:recurrence_id, :text, null: false, default: "")
      add(:etag, :text)
      add(:raw, :text)
      add(:summary, :text)
      add(:description, :text)
      add(:location, :text)
      add(:starts_at, :text, null: false)
      add(:ends_at, :text)
      add(:timezone, :text)
      add(:all_day, :boolean, null: false, default: false)
      add(:recurrence_rules, {:array, :text}, null: false, default: [])
      add(:excluded_dates, {:array, :text}, null: false, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:calendar_events, [:collection_id, :resource_href, :uid, :recurrence_id],
        name: :calendar_events_resource_identity_index
      )
    )

    create(index(:calendar_events, [:collection_id, :starts_at, :id]))

    create(
      constraint(:calendar_events, :calendar_events_href_present,
        check: "length(btrim(resource_href)) > 0"
      )
    )

    create(
      constraint(:calendar_events, :calendar_events_uid_present, check: "length(btrim(uid)) > 0")
    )
  end
end

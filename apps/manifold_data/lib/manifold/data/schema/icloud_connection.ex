defmodule Manifold.Data.Schema.ICloudConnection do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(pending syncing connected failed reconnect_required disabled)

  schema "icloud_connections" do
    field(:apple_id, :string)
    field(:password_ciphertext, :binary, redact: true)
    field(:enabled, :boolean, default: true)
    field(:contacts_enabled, :boolean, default: true)
    field(:calendars_enabled, :boolean, default: true)
    field(:generation, :integer, default: 1)
    field(:contacts_status, :string, default: "pending")
    field(:contacts_error, :string)
    field(:contacts_synced_at, :utc_datetime_usec)
    field(:calendars_status, :string, default: "pending")
    field(:calendars_error, :string)
    field(:calendars_synced_at, :utc_datetime_usec)
    field(:next_sync_at, :utc_datetime_usec)
    field(:sync_owner, :binary_id)
    field(:sync_expires_at, :utc_datetime_usec)

    has_many(:collections, Manifold.Data.Schema.DAVCollection, foreign_key: :connection_id)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [
      :apple_id,
      :password_ciphertext,
      :enabled,
      :contacts_enabled,
      :calendars_enabled,
      :generation,
      :contacts_status,
      :contacts_error,
      :contacts_synced_at,
      :calendars_status,
      :calendars_error,
      :calendars_synced_at,
      :next_sync_at,
      :sync_owner,
      :sync_expires_at
    ])
    |> update_change(:apple_id, &String.trim/1)
    |> validate_required([
      :apple_id,
      :password_ciphertext,
      :enabled,
      :contacts_enabled,
      :calendars_enabled,
      :generation,
      :contacts_status,
      :calendars_status
    ])
    |> validate_length(:apple_id, max: 320)
    |> validate_number(:generation, greater_than: 0)
    |> validate_inclusion(:contacts_status, @statuses)
    |> validate_inclusion(:calendars_status, @statuses)
    |> check_constraint(:apple_id, name: :icloud_connections_apple_id_present)
    |> check_constraint(:generation, name: :icloud_connections_generation_positive)
    |> check_constraint(:contacts_status, name: :icloud_connections_contacts_status_valid)
    |> check_constraint(:calendars_status, name: :icloud_connections_calendars_status_valid)
  end
end

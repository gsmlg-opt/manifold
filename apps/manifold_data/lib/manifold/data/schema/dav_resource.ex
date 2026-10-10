defmodule Manifold.Data.Schema.DAVResource do
  @moduledoc "Durable intent and remote baseline for one complete DAV document."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(pending synced paused conflict uncertain failed)

  schema "dav_resources" do
    field(:kind, :string)
    field(:account_id, :binary_id)
    belongs_to(:connection, Manifold.Data.Schema.ICloudConnection)
    belongs_to(:collection, Manifold.Data.Schema.DAVCollection)
    field(:href, :string)
    field(:uid, :string)
    field(:base_raw, :string)
    field(:etag, :string)
    field(:desired_revision, :integer, default: 0)
    field(:acknowledged_revision, :integer, default: 0)
    field(:status, :string, default: "pending")
    field(:operation, :string, default: "upsert")
    field(:sent_revision, :integer)
    field(:sent_operation, :string)
    field(:sent_generation, :integer)
    field(:sent_raw, :string)
    field(:sent_contact_values, :map)
    field(:sent_etag, :string)
    field(:remote_raw, :string)
    field(:remote_etag, :string)
    field(:last_error, :string)
    field(:retry_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(resource, attrs) do
    resource
    |> cast(attrs, [
      :kind,
      :account_id,
      :connection_id,
      :collection_id,
      :href,
      :uid,
      :base_raw,
      :etag,
      :desired_revision,
      :acknowledged_revision,
      :status,
      :operation,
      :sent_revision,
      :sent_operation,
      :sent_generation,
      :sent_raw,
      :sent_contact_values,
      :sent_etag,
      :remote_raw,
      :remote_etag,
      :last_error,
      :retry_at
    ])
    |> validate_required([
      :kind,
      :href,
      :uid,
      :desired_revision,
      :acknowledged_revision,
      :status,
      :operation
    ])
    |> validate_inclusion(:kind, ["contacts", "calendars"])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:operation, ["upsert", "delete"])
    |> validate_number(:desired_revision, greater_than_or_equal_to: 0)
    |> validate_number(:acknowledged_revision, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:account_id)
    |> foreign_key_constraint(:connection_id)
    |> foreign_key_constraint(:collection_id)
    |> unique_constraint([:collection_id, :href], error_key: :href)
  end
end

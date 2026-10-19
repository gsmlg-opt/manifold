defmodule Manifold.Data.Schema.CalendarSyncResource do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "calendar_sync_resources" do
    belongs_to :binding, Manifold.Data.Schema.CalendarBinding
    field :remote_resource_id, :string
    field :href, :string
    field :base_raw, :string
    field :etag, :string
    field :remote_raw, :string
    field :remote_etag, :string
    field :remote_presence, :string, default: "unknown"
    field :status, :string, default: "pending"
    field :provider_metadata, :map, default: %{}
    field :retry_at, :utc_datetime_usec
    field :last_error, :string
    field :legacy_resource_id, :binary_id
    field :legacy_snapshot, :map, default: %{}
    has_many :event_bindings, Manifold.Data.Schema.CalendarEventBinding, foreign_key: :resource_id
    has_many :attempts, Manifold.Data.Schema.CalendarSyncAttempt, foreign_key: :resource_id
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(
      attrs,
      [
        :binding_id,
        :remote_resource_id,
        :href,
        :base_raw,
        :etag,
        :remote_raw,
        :remote_etag,
        :remote_presence,
        :status,
        :provider_metadata,
        :retry_at,
        :last_error,
        :legacy_resource_id,
        :legacy_snapshot
      ],
      empty_values: []
    )
    |> validate_required([:binding_id, :remote_resource_id, :remote_presence, :status])
    |> validate_inclusion(:remote_presence, ~w(unknown present deleted))
    |> validate_inclusion(:status, ~w(pending synced conflict uncertain failed limited))
    |> foreign_key_constraint(:binding_id)
    |> unique_constraint([:binding_id, :remote_resource_id])
    |> unique_constraint(:legacy_resource_id)
  end
end

defmodule Manifold.Data.Schema.CalendarBinding do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "calendar_bindings" do
    belongs_to :calendar, Manifold.Data.Schema.Calendar
    belongs_to :connection, Manifold.Data.Schema.CalendarConnection
    field :remote_calendar_id, :string
    field :name, :string
    field :direction, :string, default: "bidirectional"
    field :capabilities, :map, default: %{}
    field :state, :string, default: "preview"
    field :generation, :integer, default: 1
    field :checkpoint, :map, default: %{}
    field :enrollment_manifest, :map, default: %{}
    field :lease_owner, :binary_id
    field :lease_expires_at, :utc_datetime_usec
    field :suppressed_at, :utc_datetime_usec
    field :legacy_collection_id, :binary_id
    field :last_error, :string
    field :synced_at, :utc_datetime_usec
    has_many :resources, Manifold.Data.Schema.CalendarSyncResource, foreign_key: :binding_id
    has_many :event_bindings, Manifold.Data.Schema.CalendarEventBinding, foreign_key: :binding_id
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(
      attrs,
      [
        :calendar_id,
        :connection_id,
        :remote_calendar_id,
        :name,
        :direction,
        :capabilities,
        :state,
        :generation,
        :checkpoint,
        :enrollment_manifest,
        :lease_owner,
        :lease_expires_at,
        :suppressed_at,
        :legacy_collection_id,
        :last_error,
        :synced_at
      ],
      empty_values: []
    )
    |> validate_required([:connection_id, :remote_calendar_id, :direction, :state, :generation])
    |> validate_inclusion(:direction, ~w(bidirectional inbound))
    |> validate_inclusion(:state, ~w(preview active paused detached unavailable))
    |> foreign_key_constraint(:calendar_id)
    |> foreign_key_constraint(:connection_id)
    |> unique_constraint([:connection_id, :remote_calendar_id])
    |> unique_constraint(:legacy_collection_id)
  end
end

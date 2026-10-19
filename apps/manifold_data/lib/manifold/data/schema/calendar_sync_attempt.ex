defmodule Manifold.Data.Schema.CalendarSyncAttempt do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "calendar_sync_attempts" do
    belongs_to :resource, Manifold.Data.Schema.CalendarSyncResource
    field :connection_generation, :integer
    field :binding_generation, :integer
    field :operation, :string
    field :destination, :string
    field :payload, :string
    field :precondition, :map, default: %{}
    field :component_revisions, :map, default: %{}
    field :sent_projections, :map, default: %{}
    field :state, :string, default: "prepared"
    field :response_etag, :string
    field :response_raw, :string
    field :last_error, :string
    field :dispatched_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :legacy_snapshot, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(
      attrs,
      [
        :resource_id,
        :connection_generation,
        :binding_generation,
        :operation,
        :destination,
        :payload,
        :precondition,
        :component_revisions,
        :sent_projections,
        :state,
        :response_etag,
        :response_raw,
        :last_error,
        :dispatched_at,
        :completed_at,
        :legacy_snapshot
      ],
      empty_values: []
    )
    |> validate_required([:resource_id, :operation, :destination, :state])
    |> validate_inclusion(:operation, ~w(upsert delete))
    |> validate_inclusion(:state, ~w(prepared dispatched uncertain succeeded failed conflict))
    |> foreign_key_constraint(:resource_id)
    |> unique_constraint(:resource_id, name: :calendar_sync_attempts_unresolved_index)
  end
end

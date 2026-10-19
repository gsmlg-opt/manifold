defmodule Manifold.Data.Schema.CalendarEventBinding do
  @moduledoc false
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "calendar_event_bindings" do
    belongs_to :binding, Manifold.Data.Schema.CalendarBinding
    belongs_to :event, Manifold.Data.Schema.CalendarEvent
    belongs_to :resource, Manifold.Data.Schema.CalendarSyncResource
    field :remote_component_key, :string
    field :desired_revision, :integer, default: 0
    field :acknowledged_revision, :integer, default: 0
    field :base_projection, :map, default: %{}
    field :projection_fields, {:array, :string}, default: []
    field :projection_version, :integer, default: 1
    field :conflict, :map
    field :state, :string, default: "enrolled"
    field :last_error, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(
      attrs,
      [
        :binding_id,
        :event_id,
        :resource_id,
        :remote_component_key,
        :desired_revision,
        :acknowledged_revision,
        :base_projection,
        :projection_fields,
        :projection_version,
        :conflict,
        :state,
        :last_error
      ],
      empty_values: []
    )
    |> validate_required([
      :binding_id,
      :event_id,
      :resource_id,
      :remote_component_key,
      :desired_revision,
      :acknowledged_revision,
      :state
    ])
    |> validate_inclusion(:state, ~w(enrolled suppressed limited))
    |> validate_number(:desired_revision, greater_than_or_equal_to: 0)
    |> validate_number(:acknowledged_revision, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:binding_id)
    |> foreign_key_constraint(:event_id)
    |> foreign_key_constraint(:resource_id)
    |> unique_constraint([:binding_id, :event_id])
    |> unique_constraint([:resource_id, :remote_component_key])
    |> check_constraint(:desired_revision, name: :calendar_event_binding_revisions_valid)
  end
end

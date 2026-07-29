defmodule Manifold.Edge.Schema.DeliveryEvent do
  @moduledoc false

  use Manifold.Edge.Schema
  import Ecto.Changeset

  schema "edge_delivery_events" do
    field(:event_type, :string)
    field(:metadata, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)

    belongs_to(:delivery, Manifold.Edge.Schema.Delivery)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:delivery_id, :event_type, :metadata, :occurred_at])
    |> validate_required([:delivery_id, :event_type, :metadata, :occurred_at])
    |> foreign_key_constraint(:delivery_id)
  end
end

defmodule Manifold.Outbound.Schema.OutboundEvent do
  @moduledoc false

  use Manifold.Outbound.Schema
  import Ecto.Changeset

  schema "outbound_events" do
    field(:outbound_message_id, :binary_id)
    field(:event_type, :string)
    field(:metadata, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(event, attrs) do
    event
    |> cast(attrs, [:outbound_message_id, :event_type, :metadata, :occurred_at])
    |> validate_required([:outbound_message_id, :event_type, :occurred_at])
    |> foreign_key_constraint(:outbound_message_id)
  end
end

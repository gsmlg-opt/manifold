defmodule Manifold.Ingest.Schema.MessageEvent do
  @moduledoc false

  use Manifold.Ingest.Schema
  import Ecto.Changeset

  schema "message_events" do
    field(:event_type, :string)
    field(:metadata, :map, default: %{})
    field(:occurred_at, :utc_datetime_usec)

    belongs_to(:inbound_delivery, Manifold.Ingest.Schema.InboundDelivery)

    timestamps(type: :utc_datetime_usec)
  end

  def event_changeset(inbound_delivery_id, event_type, metadata, occurred_at) do
    %__MODULE__{}
    |> cast(
      %{
        inbound_delivery_id: inbound_delivery_id,
        event_type: event_type,
        metadata: metadata,
        occurred_at: occurred_at
      },
      [:inbound_delivery_id, :event_type, :metadata, :occurred_at]
    )
    |> validate_required([:inbound_delivery_id, :event_type, :metadata, :occurred_at])
  end
end

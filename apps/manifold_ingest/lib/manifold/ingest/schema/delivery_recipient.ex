defmodule Manifold.Ingest.Schema.DeliveryRecipient do
  @moduledoc false

  use Manifold.Ingest.Schema

  schema "delivery_recipients" do
    field(:original_address, :string)
    field(:canonical_address, :string)
    field(:plus_tag, :string)
    field(:mailbox_id, :binary_id)

    belongs_to(:inbound_delivery, Manifold.Ingest.Schema.InboundDelivery)

    timestamps(type: :utc_datetime_usec)
  end
end

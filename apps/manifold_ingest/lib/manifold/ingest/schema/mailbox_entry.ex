defmodule Manifold.Ingest.Schema.MailboxEntry do
  @moduledoc false

  use Manifold.Ingest.Schema

  schema "mailbox_entries" do
    field(:mailbox_id, :binary_id)
    field(:original_recipient, :string)
    field(:status, :string)

    belongs_to(:inbound_delivery, Manifold.Ingest.Schema.InboundDelivery)

    timestamps(type: :utc_datetime_usec)
  end
end

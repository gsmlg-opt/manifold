defmodule Manifold.Ingest.AcceptanceReceipt do
  @moduledoc """
  Public durable receipt for an edge-originated inbound delivery.
  """

  @enforce_keys [
    :source_id,
    :external_delivery_id,
    :inbound_delivery_id,
    :ingest_id,
    :raw_sha256,
    :raw_size,
    :routes_sha256,
    :existing?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source_id: String.t(),
          external_delivery_id: String.t(),
          inbound_delivery_id: Ecto.UUID.t(),
          ingest_id: String.t(),
          raw_sha256: String.t(),
          raw_size: non_neg_integer(),
          routes_sha256: String.t(),
          existing?: boolean()
        }
end

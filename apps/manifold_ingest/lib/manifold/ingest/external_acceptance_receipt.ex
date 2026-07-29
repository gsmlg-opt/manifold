defmodule Manifold.Ingest.ExternalAcceptanceReceipt do
  @moduledoc """
  Public durable receipt for a provider-imported message.
  """

  @enforce_keys [
    :provider,
    :source_id,
    :external_message_id,
    :inbound_delivery_id,
    :ingest_id,
    :raw_sha256,
    :raw_size,
    :target_sha256,
    :existing?
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          provider: String.t(),
          source_id: String.t(),
          external_message_id: String.t(),
          inbound_delivery_id: Ecto.UUID.t(),
          ingest_id: String.t(),
          raw_sha256: String.t(),
          raw_size: non_neg_integer(),
          target_sha256: String.t(),
          existing?: boolean()
        }
end

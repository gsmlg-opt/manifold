defmodule Manifold.Mail.InboundSource do
  @moduledoc """
  Immutable transport-neutral descriptor for an archived inbound message.
  """

  @enforce_keys [
    :inbound_delivery_id,
    :raw_object_key,
    :raw_size,
    :raw_sha256,
    :received_at
  ]
  defstruct [:source_kind | @enforce_keys]

  @type t :: %__MODULE__{
          inbound_delivery_id: Ecto.UUID.t(),
          raw_object_key: String.t(),
          raw_size: non_neg_integer(),
          raw_sha256: String.t(),
          received_at: DateTime.t(),
          source_kind: String.t() | nil
        }
end

defmodule Manifold.Security.Input do
  @moduledoc """
  Trusted transport and raw-object projection for security adapters.
  """

  @enforce_keys [
    :inbound_delivery_id,
    :peer_ip,
    :helo,
    :envelope_from,
    :received_at,
    :raw_object_key,
    :raw_size,
    :raw_sha256
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          inbound_delivery_id: Ecto.UUID.t(),
          peer_ip: String.t(),
          helo: String.t() | nil,
          envelope_from: String.t(),
          received_at: DateTime.t(),
          raw_object_key: String.t(),
          raw_size: non_neg_integer(),
          raw_sha256: String.t()
        }
end

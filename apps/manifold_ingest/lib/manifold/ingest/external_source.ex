defmodule Manifold.Ingest.ExternalSource do
  @moduledoc """
  Trusted transport-neutral identity for a provider-imported raw message.
  """

  @enforce_keys [
    :provider,
    :account_id,
    :external_message_id,
    :mailbox_id,
    :storage_domain_id,
    :recipient_address,
    :received_at,
    :ingest_id
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          provider: String.t(),
          account_id: String.t(),
          external_message_id: String.t(),
          mailbox_id: Ecto.UUID.t(),
          storage_domain_id: Ecto.UUID.t(),
          recipient_address: String.t(),
          received_at: DateTime.t(),
          ingest_id: String.t()
        }
end

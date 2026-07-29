defmodule Manifold.Accounts.SenderIdentity do
  @moduledoc """
  Public immutable sender identity for outbound composition.
  """

  @enforce_keys [:mailbox_id, :domain_id, :address, :canonical_address]
  defstruct [:display_name | @enforce_keys]

  @type t :: %__MODULE__{
          mailbox_id: Ecto.UUID.t(),
          domain_id: Ecto.UUID.t(),
          display_name: String.t() | nil,
          address: String.t(),
          canonical_address: String.t()
        }
end

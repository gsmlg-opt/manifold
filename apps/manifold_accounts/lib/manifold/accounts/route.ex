defmodule Manifold.Accounts.Route do
  @moduledoc """
  Frozen recipient route accepted during an SMTP transaction.
  """

  @type t :: %__MODULE__{
          original_recipient: String.t(),
          canonical_recipient: String.t(),
          plus_tag: String.t() | nil,
          domain_id: Ecto.UUID.t(),
          mailbox_ids: [Ecto.UUID.t()]
        }

  @derive Jason.Encoder
  defstruct [:original_recipient, :canonical_recipient, :plus_tag, :domain_id, mailbox_ids: []]
end

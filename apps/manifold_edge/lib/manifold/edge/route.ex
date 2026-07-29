defmodule Manifold.Edge.Route do
  @moduledoc """
  Frozen edge route accepted during one SMTP transaction.
  """

  @enforce_keys [
    :original_recipient,
    :canonical_recipient,
    :domain_id,
    :mailbox_ids,
    :snapshot_revision
  ]
  defstruct [
    :original_recipient,
    :canonical_recipient,
    :plus_tag,
    :domain_id,
    :snapshot_revision,
    mailbox_ids: []
  ]

  @type t :: %__MODULE__{
          original_recipient: String.t(),
          canonical_recipient: String.t(),
          plus_tag: String.t() | nil,
          domain_id: String.t(),
          mailbox_ids: [String.t()],
          snapshot_revision: non_neg_integer()
        }
end

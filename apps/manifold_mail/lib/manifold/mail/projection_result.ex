defmodule Manifold.Mail.ProjectionResult do
  @moduledoc """
  Public result of an idempotent inbound mail projection.
  """

  @enforce_keys [:message_id, :state, :mailbox_ids, :parser_version, :sanitizer_version]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          message_id: Ecto.UUID.t(),
          state: :parsed | :fallback,
          mailbox_ids: [Ecto.UUID.t()],
          parser_version: pos_integer(),
          sanitizer_version: pos_integer()
        }
end

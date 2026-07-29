defmodule Manifold.Connectors.View.Account do
  @moduledoc false

  @enforce_keys [
    :id,
    :mailbox_id,
    :provider,
    :email_address,
    :status,
    :sync_enabled,
    :last_attempted_at,
    :last_synced_at,
    :last_error
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          mailbox_id: Ecto.UUID.t(),
          provider: String.t(),
          email_address: String.t(),
          status: String.t(),
          sync_enabled: boolean(),
          last_attempted_at: DateTime.t() | nil,
          last_synced_at: DateTime.t() | nil,
          last_error: String.t() | nil
        }
end

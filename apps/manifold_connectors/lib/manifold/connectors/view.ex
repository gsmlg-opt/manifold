defmodule Manifold.Connectors.View.ReceiveMethod do
  @moduledoc false

  @enforce_keys [
    :id,
    :account_id,
    :kind,
    :email_address,
    :status,
    :enabled,
    :sync_enabled,
    :last_attempted_at,
    :last_synced_at,
    :last_error
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          account_id: Ecto.UUID.t(),
          kind: String.t(),
          email_address: String.t(),
          status: String.t(),
          enabled: boolean(),
          sync_enabled: boolean(),
          last_attempted_at: DateTime.t() | nil,
          last_synced_at: DateTime.t() | nil,
          last_error: String.t() | nil
        }
end

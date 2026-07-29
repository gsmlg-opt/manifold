defmodule Manifold.Accounts.RecipientSnapshot do
  @moduledoc """
  Immutable public projection of recipient routes for a cloud ingress edge.
  """

  alias __MODULE__.{Domain, Route}

  @enforce_keys [
    :schema_version,
    :revision,
    :generated_at,
    :expires_at,
    :digest,
    :domains,
    :routes
  ]
  @derive Jason.Encoder
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          revision: non_neg_integer(),
          generated_at: DateTime.t(),
          expires_at: DateTime.t(),
          digest: String.t(),
          domains: [Domain.t()],
          routes: [Route.t()]
        }

  defmodule Domain do
    @moduledoc """
    Public routing policy for one locally hosted domain.
    """

    @enforce_keys [:id, :name, :plus_addressing_enabled]
    @derive Jason.Encoder
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            id: Ecto.UUID.t(),
            name: String.t(),
            plus_addressing_enabled: boolean()
          }
  end

  defmodule Route do
    @moduledoc """
    Public exact address route with opaque local mailbox identifiers.
    """

    @enforce_keys [
      :canonical_address,
      :domain_id,
      :mailbox_ids,
      :plus_addressing_enabled
    ]
    @derive Jason.Encoder
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            canonical_address: String.t(),
            domain_id: Ecto.UUID.t(),
            mailbox_ids: [Ecto.UUID.t()],
            plus_addressing_enabled: boolean()
          }
  end
end

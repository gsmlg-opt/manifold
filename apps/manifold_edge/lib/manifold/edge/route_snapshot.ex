defmodule Manifold.Edge.RouteSnapshot do
  @moduledoc """
  Validated recipient-route snapshot installed by a local Manifold instance.
  """

  alias __MODULE__.Route

  @enforce_keys [
    :schema_version,
    :revision,
    :digest,
    :generated_at,
    :expires_at,
    :routes
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          revision: non_neg_integer(),
          digest: String.t(),
          generated_at: DateTime.t(),
          expires_at: DateTime.t(),
          routes: [Route.t()]
        }

  defmodule Route do
    @moduledoc """
    One exact canonical recipient route in an installed snapshot.
    """

    @enforce_keys [
      :canonical_address,
      :domain_id,
      :mailbox_ids,
      :plus_addressing_enabled
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            canonical_address: String.t(),
            domain_id: String.t(),
            mailbox_ids: [String.t()],
            plus_addressing_enabled: boolean()
          }
  end
end

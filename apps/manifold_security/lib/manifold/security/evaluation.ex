defmodule Manifold.Security.Evaluation do
  @moduledoc false

  @enforce_keys [
    :spf,
    :dkim,
    :dmarc,
    :authentication_metadata,
    :malware,
    :spam,
    :policy_action,
    :policy_reasons
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
end

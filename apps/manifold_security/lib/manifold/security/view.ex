defmodule Manifold.Security.View.Assessment do
  @moduledoc false

  @enforce_keys [
    :id,
    :inbound_delivery_id,
    :evaluation_version,
    :state,
    :spf_result,
    :dkim_result,
    :dmarc_result,
    :malware_verdict,
    :spam_verdict,
    :policy_action,
    :policy_reasons,
    :policy_applied,
    :evaluated_at
  ]
  defstruct [
    :malware_signature,
    :spam_score,
    :last_error_class,
    :last_error_code,
    :last_error_message
    | @enforce_keys
  ]

  @type t :: %__MODULE__{}
end

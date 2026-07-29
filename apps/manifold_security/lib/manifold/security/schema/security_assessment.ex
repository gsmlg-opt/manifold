defmodule Manifold.Security.Schema.SecurityAssessment do
  @moduledoc false

  use Manifold.Security.Schema
  import Ecto.Changeset

  schema "security_assessments" do
    field(:inbound_delivery_id, :binary_id)
    field(:evaluation_version, :integer)
    field(:state, :string)
    field(:spf_result, :string)
    field(:dkim_result, :string)
    field(:dmarc_result, :string)
    field(:authentication_metadata, :map, default: %{})
    field(:malware_verdict, :string)
    field(:malware_signature, :string)
    field(:malware_metadata, :map, default: %{})
    field(:spam_verdict, :string)
    field(:spam_score, :float)
    field(:spam_metadata, :map, default: %{})
    field(:policy_action, :string)
    field(:policy_reasons, {:array, :string}, default: [])
    field(:policy_applied, :boolean, default: false)
    field(:evaluated_at, :utc_datetime_usec)
    field(:last_error_class, :string)
    field(:last_error_code, :string)
    field(:last_error_message, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(assessment, attrs) do
    assessment
    |> cast(attrs, [
      :inbound_delivery_id,
      :evaluation_version,
      :state,
      :spf_result,
      :dkim_result,
      :dmarc_result,
      :authentication_metadata,
      :malware_verdict,
      :malware_signature,
      :malware_metadata,
      :spam_verdict,
      :spam_score,
      :spam_metadata,
      :policy_action,
      :policy_reasons,
      :policy_applied,
      :evaluated_at,
      :last_error_class,
      :last_error_code,
      :last_error_message
    ])
    |> validate_required([
      :inbound_delivery_id,
      :evaluation_version,
      :state,
      :spf_result,
      :dkim_result,
      :dmarc_result,
      :malware_verdict,
      :spam_verdict,
      :policy_action,
      :policy_applied,
      :evaluated_at
    ])
    |> validate_number(:evaluation_version, greater_than: 0)
    |> validate_inclusion(:state, ~w(evaluated failed))
    |> validate_inclusion(:spf_result, authentication_results())
    |> validate_inclusion(:dkim_result, authentication_results())
    |> validate_inclusion(:dmarc_result, authentication_results())
    |> validate_inclusion(:malware_verdict, ~w(clean infected suspicious temperror not_evaluated))
    |> validate_inclusion(:spam_verdict, ~w(ham spam temperror not_evaluated))
    |> validate_number(:spam_score, greater_than_or_equal_to: 0, less_than_or_equal_to: 1)
    |> validate_inclusion(:policy_action, ~w(allow quarantine released))
    |> foreign_key_constraint(:inbound_delivery_id)
    |> unique_constraint(:inbound_delivery_id)
  end

  defp authentication_results,
    do: ~w(pass fail softfail neutral none temperror permerror not_evaluated)
end

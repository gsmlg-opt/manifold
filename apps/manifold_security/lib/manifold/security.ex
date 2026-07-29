defmodule Manifold.Security do
  @moduledoc """
  Public inbound security assessment and quarantine context.
  """

  import Ecto.Query

  alias Manifold.Core.Error
  alias Manifold.Mail
  alias Manifold.Repo
  alias Manifold.Security.{Evaluator, Input}
  alias Manifold.Security.Schema.{SecurityAssessment, SecurityEvent}
  alias Manifold.Security.View

  @default_version 1

  @spec evaluate(Input.t(), Keyword.t()) ::
          {:ok, View.Assessment.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def evaluate(%Input{} = input, opts \\ []) do
    version = Keyword.get(opts, :evaluation_version, @default_version)

    case current_assessment(input.inbound_delivery_id, version) do
      %SecurityAssessment{} = assessment ->
        reconcile_policy(assessment, opts)

      nil ->
        evaluator_opts =
          Keyword.take(opts, [
            :authentication_adapter,
            :malware_adapter,
            :spam_adapter,
            :adapter_config,
            :spam_threshold
          ])

        case Evaluator.evaluate(input, evaluator_opts) do
          {:ok, evaluation} ->
            with {:ok, assessment} <- persist_evaluation(input, evaluation, version),
                 :ok <- maybe_fail(opts, :after_assessment_before_policy) do
              reconcile_policy(assessment, opts)
            end

          {:error, %Error{} = error} ->
            with {:ok, failed} <- persist_failure(input, error, version) do
              emit_evaluation_failed(failed)
              {:error, error}
            end
        end
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec get_assessment(Ecto.UUID.t()) ::
          {:ok, View.Assessment.t()} | {:error, Error.t()}
  def get_assessment(inbound_delivery_id) do
    case Repo.get_by(SecurityAssessment, inbound_delivery_id: inbound_delivery_id) do
      %SecurityAssessment{} = assessment -> {:ok, assessment_view(assessment)}
      nil -> {:error, error(:permanent, :assessment_not_found, "security assessment not found")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec list_quarantined() :: [View.Assessment.t()]
  def list_quarantined do
    SecurityAssessment
    |> where([assessment], assessment.policy_action == "quarantine")
    |> order_by([assessment], desc: assessment.evaluated_at, desc: assessment.id)
    |> Repo.all()
    |> Enum.map(&assessment_view/1)
  end

  @spec assessments_by_delivery([Ecto.UUID.t()]) :: %{
          optional(Ecto.UUID.t()) => View.Assessment.t()
        }
  def assessments_by_delivery(inbound_delivery_ids) when is_list(inbound_delivery_ids) do
    SecurityAssessment
    |> where([assessment], assessment.inbound_delivery_id in ^inbound_delivery_ids)
    |> Repo.all()
    |> Map.new(fn assessment ->
      {assessment.inbound_delivery_id, assessment_view(assessment)}
    end)
  end

  @spec policy_applied?(Ecto.UUID.t(), pos_integer()) :: boolean()
  def policy_applied?(inbound_delivery_id, evaluation_version \\ @default_version) do
    SecurityAssessment
    |> where(
      [assessment],
      assessment.inbound_delivery_id == ^inbound_delivery_id and
        assessment.evaluation_version == ^evaluation_version and
        assessment.policy_applied
    )
    |> Repo.exists?()
  end

  @spec policy_applied_delivery_ids([Ecto.UUID.t()], pos_integer()) :: MapSet.t(Ecto.UUID.t())
  def policy_applied_delivery_ids(inbound_delivery_ids, evaluation_version \\ @default_version) do
    SecurityAssessment
    |> where(
      [assessment],
      assessment.inbound_delivery_id in ^inbound_delivery_ids and
        assessment.evaluation_version == ^evaluation_version and
        assessment.policy_applied
    )
    |> select([assessment], assessment.inbound_delivery_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @spec release(Ecto.UUID.t(), Keyword.t()) ::
          {:ok, View.Assessment.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def release(assessment_id, opts \\ []) do
    case Repo.get(SecurityAssessment, assessment_id) do
      nil ->
        {:error, error(:permanent, :assessment_not_found, "security assessment not found")}

      %SecurityAssessment{policy_action: "released", policy_applied: true} = assessment ->
        {:ok, assessment_view(assessment)}

      %SecurityAssessment{} = assessment ->
        with {:ok, _count} <- quarantine(opts).(assessment.inbound_delivery_id, false),
             :ok <- maybe_fail(opts, :after_release_before_commit),
             {:ok, released} <- persist_release(assessment.id) do
          emit_policy_committed(released)
          {:ok, assessment_view(released)}
        else
          {:error, %Error{} = error} -> {:error, error}
          {:error, reason} -> {:error, policy_error(reason)}
        end
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  defp current_assessment(delivery_id, version) do
    Repo.get_by(SecurityAssessment,
      inbound_delivery_id: delivery_id,
      evaluation_version: version,
      state: "evaluated"
    )
  end

  defp persist_evaluation(input, evaluation, version) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      existing =
        SecurityAssessment
        |> where([assessment], assessment.inbound_delivery_id == ^input.inbound_delivery_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      attrs = evaluation_attrs(input, evaluation, version, now)

      assessment =
        case existing do
          nil ->
            %SecurityAssessment{}
            |> SecurityAssessment.changeset(attrs)
            |> Repo.insert!()

          %SecurityAssessment{} = assessment ->
            assessment
            |> SecurityAssessment.changeset(attrs)
            |> Repo.update!()
        end

      insert_event!(
        assessment,
        "evaluation_completed",
        %{
          evaluation_version: version,
          policy_action: Atom.to_string(evaluation.policy_action),
          policy_reasons: Enum.map(evaluation.policy_reasons, &Atom.to_string/1)
        },
        now
      )

      assessment
    end)
    |> normalize_transaction()
  end

  defp persist_failure(input, error, version) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      existing =
        SecurityAssessment
        |> where([assessment], assessment.inbound_delivery_id == ^input.inbound_delivery_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      attrs = %{
        inbound_delivery_id: input.inbound_delivery_id,
        evaluation_version: version,
        state: "failed",
        spf_result: "not_evaluated",
        dkim_result: "not_evaluated",
        dmarc_result: "not_evaluated",
        authentication_metadata: %{},
        malware_verdict: "not_evaluated",
        malware_signature: nil,
        malware_metadata: %{},
        spam_verdict: "not_evaluated",
        spam_score: nil,
        spam_metadata: %{},
        policy_action: "quarantine",
        policy_reasons: ["evaluation_failed"],
        policy_applied: false,
        evaluated_at: now,
        last_error_class: Atom.to_string(error.class),
        last_error_code: Atom.to_string(error.reason),
        last_error_message: error.message
      }

      failed =
        case existing do
          nil ->
            %SecurityAssessment{}
            |> SecurityAssessment.changeset(attrs)
            |> Repo.insert!()

          %SecurityAssessment{} = assessment ->
            assessment
            |> SecurityAssessment.changeset(attrs)
            |> Repo.update!()
        end

      insert_event!(
        failed,
        "evaluation_failed",
        %{class: error.class, reason: error.reason},
        now
      )

      failed
    end)
    |> normalize_transaction()
  end

  defp reconcile_policy(%SecurityAssessment{policy_applied: true} = assessment, _opts),
    do: {:ok, assessment_view(assessment)}

  defp reconcile_policy(assessment, opts) do
    quarantined? = assessment.policy_action == "quarantine"

    with {:ok, _count} <- quarantine(opts).(assessment.inbound_delivery_id, quarantined?),
         :ok <- maybe_fail(opts, :after_policy_before_finalize),
         {:ok, finalized} <- finalize_policy(assessment.id, quarantined?) do
      emit_policy_committed(finalized)
      {:ok, assessment_view(finalized)}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, policy_error(reason)}
    end
  end

  defp finalize_policy(assessment_id, quarantined?) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      assessment =
        SecurityAssessment
        |> where([assessment], assessment.id == ^assessment_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if assessment.policy_applied do
        assessment
      else
        finalized =
          assessment
          |> Ecto.Changeset.change(policy_applied: true)
          |> Repo.update!()

        if quarantined? do
          insert_event!(
            finalized,
            "quarantine_applied",
            %{reasons: finalized.policy_reasons},
            now
          )
        end

        finalized
      end
    end)
    |> normalize_transaction()
  end

  defp persist_release(assessment_id) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      assessment =
        SecurityAssessment
        |> where([assessment], assessment.id == ^assessment_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      if assessment.policy_action == "released" and assessment.policy_applied do
        assessment
      else
        released =
          assessment
          |> Ecto.Changeset.change(policy_action: "released", policy_applied: true)
          |> Repo.update!()

        insert_event!(released, "released", %{}, now)
        released
      end
    end)
    |> normalize_transaction()
  end

  defp evaluation_attrs(input, evaluation, version, now) do
    %{
      inbound_delivery_id: input.inbound_delivery_id,
      evaluation_version: version,
      state: "evaluated",
      spf_result: Atom.to_string(evaluation.spf),
      dkim_result: Atom.to_string(evaluation.dkim),
      dmarc_result: Atom.to_string(evaluation.dmarc),
      authentication_metadata: evaluation.authentication_metadata,
      malware_verdict: Atom.to_string(evaluation.malware.verdict),
      malware_signature: Map.get(evaluation.malware, :signature),
      malware_metadata: Map.get(evaluation.malware, :metadata, %{}),
      spam_verdict: Atom.to_string(evaluation.spam.verdict),
      spam_score: Map.get(evaluation.spam, :score),
      spam_metadata: Map.get(evaluation.spam, :metadata, %{}),
      policy_action: Atom.to_string(evaluation.policy_action),
      policy_reasons: Enum.map(evaluation.policy_reasons, &Atom.to_string/1),
      policy_applied: false,
      evaluated_at: now,
      last_error_class: nil,
      last_error_code: nil,
      last_error_message: nil
    }
  end

  defp insert_event!(assessment, event_type, metadata, now) do
    %SecurityEvent{}
    |> SecurityEvent.changeset(%{
      security_assessment_id: assessment.id,
      inbound_delivery_id: assessment.inbound_delivery_id,
      event_type: event_type,
      metadata: metadata,
      occurred_at: now
    })
    |> Repo.insert!()
  end

  defp quarantine(opts),
    do: Keyword.get(opts, :quarantine, &Mail.set_delivery_quarantine/2)

  defp maybe_fail(opts, boundary) do
    if Keyword.get(opts, :fail_at) == boundary do
      {:error, error(:temporary, boundary, "injected security failure")}
    else
      :ok
    end
  end

  defp assessment_view(assessment) do
    %View.Assessment{
      id: assessment.id,
      inbound_delivery_id: assessment.inbound_delivery_id,
      evaluation_version: assessment.evaluation_version,
      state: assessment.state,
      spf_result: assessment.spf_result,
      dkim_result: assessment.dkim_result,
      dmarc_result: assessment.dmarc_result,
      malware_verdict: assessment.malware_verdict,
      malware_signature: assessment.malware_signature,
      spam_verdict: assessment.spam_verdict,
      spam_score: assessment.spam_score,
      policy_action: assessment.policy_action,
      policy_reasons: assessment.policy_reasons,
      policy_applied: assessment.policy_applied,
      evaluated_at: assessment.evaluated_at,
      last_error_class: assessment.last_error_class,
      last_error_code: assessment.last_error_code,
      last_error_message: assessment.last_error_message
    }
  end

  defp normalize_transaction({:ok, value}), do: {:ok, value}
  defp normalize_transaction({:error, reason}), do: {:error, database_error(reason)}

  defp policy_error(reason),
    do:
      error(:temporary, :quarantine_failed, "mail quarantine update failed", %{
        reason: inspect(reason)
      })

  defp emit_policy_committed(assessment) do
    :telemetry.execute(
      [:manifold, :security, :policy, :committed],
      %{assessment_count: 1},
      %{
        delivery_id: assessment.inbound_delivery_id,
        policy_action: assessment.policy_action
      }
    )
  end

  defp emit_evaluation_failed(assessment) do
    :telemetry.execute(
      [:manifold, :security, :evaluation, :failed],
      %{assessment_count: 1},
      %{
        delivery_id: assessment.inbound_delivery_id,
        error_class: assessment.last_error_class,
        error_code: assessment.last_error_code
      }
    )
  end

  defp database_error(reason),
    do:
      error(:temporary, :database_unavailable, "security database operation failed", %{
        reason: inspect(reason)
      })

  defp error(class, reason, message, details \\ %{}),
    do: Error.new(class, reason, message, details)
end

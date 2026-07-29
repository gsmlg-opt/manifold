defmodule Manifold.Repo.Migrations.CreateSecurityAssessments do
  use Ecto.Migration

  def change do
    create table(:security_assessments, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :inbound_delivery_id,
        references(:inbound_deliveries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:evaluation_version, :integer, null: false)
      add(:state, :text, null: false)
      add(:spf_result, :text, null: false)
      add(:dkim_result, :text, null: false)
      add(:dmarc_result, :text, null: false)
      add(:authentication_metadata, :map, null: false, default: %{})
      add(:malware_verdict, :text, null: false)
      add(:malware_signature, :text)
      add(:malware_metadata, :map, null: false, default: %{})
      add(:spam_verdict, :text, null: false)
      add(:spam_score, :float)
      add(:spam_metadata, :map, null: false, default: %{})
      add(:policy_action, :text, null: false)
      add(:policy_reasons, {:array, :text}, null: false, default: [])
      add(:policy_applied, :boolean, null: false, default: false)
      add(:evaluated_at, :utc_datetime_usec)
      add(:last_error_class, :text)
      add(:last_error_code, :text)
      add(:last_error_message, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:security_assessments, [:inbound_delivery_id]))

    create(
      index(:security_assessments, [:policy_action, :policy_applied, :evaluated_at],
        name: :security_assessments_policy_index
      )
    )

    create(
      constraint(:security_assessments, :security_assessments_version_positive,
        check: "evaluation_version > 0"
      )
    )

    create(
      constraint(:security_assessments, :security_assessments_state_valid,
        check: "state IN ('evaluated', 'failed')"
      )
    )

    authentication_results =
      "'pass', 'fail', 'softfail', 'neutral', 'none', 'temperror', 'permerror', 'not_evaluated'"

    for field <- ~w(spf_result dkim_result dmarc_result) do
      create(
        constraint(:security_assessments, :"security_assessments_#{field}_valid",
          check: "#{field} IN (#{authentication_results})"
        )
      )
    end

    create(
      constraint(:security_assessments, :security_assessments_malware_verdict_valid,
        check:
          "malware_verdict IN ('clean', 'infected', 'suspicious', 'temperror', 'not_evaluated')"
      )
    )

    create(
      constraint(:security_assessments, :security_assessments_spam_verdict_valid,
        check: "spam_verdict IN ('ham', 'spam', 'temperror', 'not_evaluated')"
      )
    )

    create(
      constraint(:security_assessments, :security_assessments_spam_score_valid,
        check: "spam_score IS NULL OR (spam_score >= 0 AND spam_score <= 1)"
      )
    )

    create(
      constraint(:security_assessments, :security_assessments_policy_action_valid,
        check: "policy_action IN ('allow', 'quarantine', 'released')"
      )
    )

    create table(:security_events, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :security_assessment_id,
        references(:security_assessments, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :inbound_delivery_id,
        references(:inbound_deliveries, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:event_type, :text, null: false)
      add(:metadata, :map, null: false, default: %{})
      add(:occurred_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:security_events, [:inbound_delivery_id, :occurred_at]))
    create(index(:security_events, [:security_assessment_id, :occurred_at]))
  end
end

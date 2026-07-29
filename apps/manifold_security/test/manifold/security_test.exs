defmodule Manifold.SecurityTest do
  use Manifold.DataCase, async: true

  alias Manifold.Security
  alias Manifold.Security.Input
  alias Manifold.Security.Schema.{SecurityAssessment, SecurityEvent}
  alias Manifold.Repo

  defmodule InfectedAdapter do
    @behaviour Manifold.Security.MalwareAdapter

    @impl true
    def scan(_config, _input),
      do: {:ok, %{verdict: :infected, signature: "test-malware", metadata: %{}}}
  end

  defmodule UnavailableAdapter do
    @behaviour Manifold.Security.MalwareAdapter

    @impl true
    def scan(_config, _input) do
      {:error,
       Manifold.Core.Error.new(
         :temporary,
         :scanner_unavailable,
         "malware scanner is unavailable"
       )}
    end
  end

  test "persists explicit not-evaluated results and audit event" do
    input = input_fixture()

    assert {:ok, assessment} = Security.evaluate(input)
    assert assessment.state == "evaluated"
    assert assessment.spf_result == "not_evaluated"
    assert assessment.dkim_result == "not_evaluated"
    assert assessment.dmarc_result == "not_evaluated"
    assert assessment.malware_verdict == "not_evaluated"
    assert assessment.spam_verdict == "not_evaluated"
    assert assessment.policy_action == "allow"
    assert assessment.policy_applied

    assert [%SecurityEvent{event_type: "evaluation_completed"}] =
             Repo.all(SecurityEvent)
  end

  test "positive evidence persists before quarantine and finalizes applied policy" do
    input = input_fixture()
    test_pid = self()

    quarantine = fn delivery_id, quarantined ->
      send(test_pid, {:quarantine, delivery_id, quarantined})
      {:ok, 1}
    end

    assert {:ok, assessment} =
             Security.evaluate(input,
               malware_adapter: InfectedAdapter,
               quarantine: quarantine
             )

    assert_receive {:quarantine, delivery_id, true}
    assert delivery_id == input.inbound_delivery_id
    assert assessment.policy_action == "quarantine"
    assert assessment.policy_reasons == ["malware"]
    assert assessment.policy_applied

    assert Enum.map(Repo.all(SecurityEvent), & &1.event_type) == [
             "evaluation_completed",
             "quarantine_applied"
           ]
  end

  test "retry repairs failure after assessment commit without duplicating evaluation" do
    input = input_fixture()

    assert {:error, %{reason: :after_assessment_before_policy}} =
             Security.evaluate(input,
               malware_adapter: InfectedAdapter,
               fail_at: :after_assessment_before_policy
             )

    persisted = Repo.get_by!(SecurityAssessment, inbound_delivery_id: input.inbound_delivery_id)
    refute persisted.policy_applied

    assert {:ok, repaired} =
             Security.evaluate(input,
               malware_adapter: InfectedAdapter,
               quarantine: fn _delivery_id, true -> {:ok, 1} end
             )

    assert repaired.policy_applied
    assert Repo.aggregate(SecurityAssessment, :count) == 1
    assert Repo.aggregate(SecurityEvent, :count, :id) == 2
  end

  test "manual release is idempotent and audited" do
    input = input_fixture()

    assert {:ok, assessment} =
             Security.evaluate(input,
               malware_adapter: InfectedAdapter,
               quarantine: fn _delivery_id, true -> {:ok, 1} end
             )

    release = fn _delivery_id, false -> {:ok, 1} end

    assert {:ok, released} = Security.release(assessment.id, quarantine: release)
    assert released.policy_action == "released"
    assert released.policy_applied

    assert {:ok, repeated} = Security.release(assessment.id, quarantine: release)
    assert repeated.id == released.id

    assert Repo.aggregate(
             from(event in SecurityEvent, where: event.event_type == "released"),
             :count
           ) == 1
  end

  test "invalid delivery IDs remain classified and mailbox scoped" do
    assert {:error, %{reason: :assessment_not_found}} =
             Security.get_assessment(Ecto.UUID.generate())

    assert {:error, %{reason: :assessment_not_found}} =
             Security.release(Ecto.UUID.generate())
  end

  test "policy applied predicate only reports committed visibility policy" do
    input = input_fixture()
    refute Security.policy_applied?(input.inbound_delivery_id)

    assert {:ok, _assessment} =
             Security.evaluate(input, quarantine: fn _delivery_id, false -> {:ok, 1} end)

    assert Security.policy_applied?(input.inbound_delivery_id)
    refute Security.policy_applied?(input.inbound_delivery_id, 2)
  end

  test "adapter failure persists classified operational state and retry replaces it" do
    input = input_fixture()

    assert {:error, %{class: :temporary, reason: :scanner_unavailable}} =
             Security.evaluate(input, malware_adapter: UnavailableAdapter)

    assert {:ok, failed} = Security.get_assessment(input.inbound_delivery_id)
    assert failed.state == "failed"
    assert failed.spf_result == "not_evaluated"
    assert failed.policy_action == "quarantine"
    refute failed.policy_applied
    assert failed.last_error_class == "temporary"
    assert failed.last_error_code == "scanner_unavailable"

    assert {:ok, repaired} =
             Security.evaluate(input, quarantine: fn _delivery_id, false -> {:ok, 1} end)

    assert repaired.state == "evaluated"
    assert repaired.policy_action == "allow"
    assert repaired.policy_applied
    assert repaired.last_error_message == nil
    assert Repo.aggregate(SecurityAssessment, :count) == 1

    assert Enum.map(Repo.all(SecurityEvent), & &1.event_type) == [
             "evaluation_failed",
             "evaluation_completed"
           ]
  end

  test "policy applied delivery IDs are returned in one public projection" do
    first = input_fixture()
    second = input_fixture()

    assert {:ok, _assessment} =
             Security.evaluate(first, quarantine: fn _delivery_id, false -> {:ok, 1} end)

    assert Security.policy_applied_delivery_ids([
             first.inbound_delivery_id,
             second.inbound_delivery_id
           ]) == MapSet.new([first.inbound_delivery_id])
  end

  defp input_fixture do
    delivery_id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO inbound_deliveries (
        id, ingest_id, peer_ip, helo, envelope_from, received_at, raw_size,
        raw_sha256, spool_bundle_path, raw_object_key, raw_storage_state,
        processing_state, inserted_at, updated_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $13)
      """,
      [
        Ecto.UUID.dump!(delivery_id),
        Ecto.UUID.generate(),
        "192.0.2.10",
        "sender.example",
        "sender@example.net",
        now,
        123,
        String.duplicate("0", 64),
        "/removed",
        "raw/trusted/message.eml",
        "archived",
        "processed",
        now
      ]
    )

    %Input{
      inbound_delivery_id: delivery_id,
      peer_ip: "192.0.2.10",
      helo: "sender.example",
      envelope_from: "sender@example.net",
      received_at: now,
      raw_object_key: "raw/trusted/message.eml",
      raw_size: 123,
      raw_sha256: String.duplicate("0", 64)
    }
  end
end

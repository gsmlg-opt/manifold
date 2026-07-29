defmodule Manifold.Outbound.SubmissionTest do
  use Manifold.DataCase, async: true

  alias Manifold.Accounts
  alias Manifold.Outbound
  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Schema.{OutboundEvent, OutboundMessage, ProviderSubmission}
  alias Manifold.Repo

  defmodule TestProvider do
    @behaviour Manifold.Outbound.Provider

    @impl true
    def submit(config, envelope) do
      send(Keyword.fetch!(config, :test_pid), {:provider_submit, envelope})
      Keyword.fetch!(config, :result)
    end
  end

  test "provider acceptance commits message and logical submission state" do
    message = queued_message_fixture()

    assert :ok =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result:
                   {:ok,
                    %Provider.Submission{
                      provider_message_id: "provider-1",
                      metadata: %{"region" => "us-east-1"}
                    }}
               ]
             )

    assert_receive {:provider_submit, envelope}
    assert envelope.subject == "Ready"
    assert envelope.to == ["person@example.net"]
    refute inspect(envelope) =~ "api_key"

    accepted = Repo.get!(OutboundMessage, message.id)
    assert accepted.state == "accepted_by_provider"
    assert %DateTime{} = accepted.accepted_at

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert submission.state == "accepted"
    assert submission.provider_message_id == "provider-1"
    assert submission.attempt_count == 1
    assert submission.provider_metadata == %{"region" => "us-east-1"}

    assert Repo.get_by!(OutboundEvent,
             outbound_message_id: message.id,
             event_type: "provider_accepted"
           )
  end

  test "provider acceptance commit failure is returned as a temporary database error" do
    message = queued_message_fixture()

    assert {:error, %{class: :temporary, reason: :database_unavailable}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result:
                   {:ok,
                    %Provider.Submission{
                      provider_message_id: "provider-rollback",
                      metadata: %{}
                    }}
               ],
               fail_at: :provider_accept_commit
             )

    assert_receive {:provider_submit, _envelope}
    assert Repo.get!(OutboundMessage, message.id).state == "submitting"

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert submission.state == "submitting"
    assert submission.provider_message_id == nil

    refute Repo.get_by(OutboundEvent,
             outbound_message_id: message.id,
             event_type: "provider_accepted"
           )
  end

  test "transient failure returns to queued and retries the byte-identical request" do
    message = queued_message_fixture()

    transient =
      {:error,
       %Provider.Error{
         class: :transient,
         code: "http_503",
         message: "later",
         http_status: 503
       }}

    assert {:error, %Provider.Error{class: :transient}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: transient]
             )

    assert_receive {:provider_submit, first_envelope}
    assert Repo.get!(OutboundMessage, message.id).state == "queued"

    assert :ok =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result:
                   {:ok, %Provider.Submission{provider_message_id: "provider-2", metadata: %{}}}
               ]
             )

    assert_receive {:provider_submit, second_envelope}
    assert second_envelope == first_envelope
    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).attempt_count == 2
  end

  test "terminal provider failure is persisted and is not retried" do
    message = queued_message_fixture()

    permanent =
      {:error,
       %Provider.Error{
         class: :permanent,
         code: "validation_error",
         message: "bad sender",
         http_status: 422
       }}

    assert {:error, %Provider.Error{class: :permanent}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: permanent]
             )

    assert Repo.get!(OutboundMessage, message.id).state == "failed"
    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).state == "failed"
  end

  test "provider error commit failure is returned as a temporary database error" do
    message = queued_message_fixture()

    transient =
      {:error,
       %Provider.Error{
         class: :transient,
         code: "http_503",
         message: "later",
         http_status: 503
       }}

    assert {:error, %{class: :temporary, reason: :database_unavailable}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: transient],
               fail_at: :provider_error_commit
             )

    assert_receive {:provider_submit, _envelope}
    assert Repo.get!(OutboundMessage, message.id).state == "submitting"

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert submission.state == "submitting"
    assert submission.last_error_code == nil

    refute Repo.get_by(OutboundEvent,
             outbound_message_id: message.id,
             event_type: "submission_retryable"
           )
  end

  test "crash after provider acceptance retries with the same idempotency key" do
    message = queued_message_fixture()

    success =
      {:ok, %Provider.Submission{provider_message_id: "provider-3", metadata: %{}}}

    assert {:error, %{reason: :after_provider_accept_before_commit}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: success],
               fail_at: :after_provider_accept_before_commit
             )

    assert_receive {:provider_submit, first_envelope}
    assert Repo.get!(OutboundMessage, message.id).state == "submitting"
    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).state == "submitting"

    assert :ok =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [test_pid: self(), result: success]
             )

    assert_receive {:provider_submit, second_envelope}
    assert second_envelope.idempotency_key == first_envelope.idempotency_key
    assert second_envelope == first_envelope
  end

  test "ambiguous submission outside the idempotency window becomes uncertain" do
    message = queued_message_fixture()
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)

    message
    |> Ecto.Changeset.change(state: "submitting")
    |> Repo.update!()

    submission
    |> Ecto.Changeset.change(
      state: "submitting",
      attempt_count: 1,
      idempotency_expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)
    )
    |> Repo.update!()

    assert {:error, %{reason: :submission_uncertain}} =
             Outbound.submit_message(message.id,
               provider: TestProvider,
               provider_config: [
                 test_pid: self(),
                 result:
                   {:ok,
                    %Provider.Submission{provider_message_id: "must-not-send", metadata: %{}}}
               ]
             )

    refute_receive {:provider_submit, _envelope}
    assert Repo.get!(OutboundMessage, message.id).state == "submission_uncertain"
    assert Repo.get!(ProviderSubmission, submission.id).state == "uncertain"
  end

  defp queued_message_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "submit#{suffix}.test"})

    {:ok, mailbox} =
      Accounts.create_mailbox(domain, %{local_part: "inbox", display_name: "Local Inbox"})

    {:ok, draft} =
      Outbound.create_draft(mailbox.id, %{
        subject: "Ready",
        text_body: "Body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)
    queued
  end
end

defmodule Manifold.Outbound.Jobs.SubmitOutboundTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, MicrosoftScopes}
  alias Manifold.Connectors.Schema.{OAuthAuthorization, SendMethod}
  alias Manifold.Outbound
  alias Manifold.Outbound.Jobs.SubmitOutbound
  alias Manifold.Outbound.LegacyResendFixture
  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Submission
  alias Manifold.Outbound.Schema.OutboundMessage
  alias Manifold.Outbound.Schema.{OutboundEvent, ProviderSubmission}
  alias Manifold.Repo

  defmodule ConfiguredProvider do
    @behaviour Manifold.Outbound.Provider

    @impl true
    def submit(config, request) do
      if test_pid = Keyword.get(config, :test_pid) do
        send(test_pid, {:configured_provider_submit, request})
      end

      Keyword.fetch!(config, :result)
    end
  end

  setup do
    old_adapter = Application.get_env(:manifold_outbound, :provider_adapter)
    old_config = Application.get_env(:manifold_outbound, :provider_config)

    Application.put_env(:manifold_outbound, :provider_adapter, ConfiguredProvider)
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})

    on_exit(fn ->
      restore_env(:provider_adapter, old_adapter)
      restore_env(:provider_config, old_config)
    end)
  end

  test "completes after managed provider acceptance" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result: {:ok, %Provider.Submission{provider_message_id: "worker-ok", metadata: %{}}}
    )

    assert :ok = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "accepted_by_provider"
  end

  test "returns transient errors to Oban for retry" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result:
        {:error,
         %Provider.Error{
           class: :transient,
           code: "http_503",
           message: "later",
           http_status: 503
         }}
    )

    assert {:error, "http_503"} = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "queued"
  end

  test "snoozes until a provider rate limit expires" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result:
        {:error,
         %Provider.Error{
           class: :transient,
           code: "http_429",
           message: "slow down",
           http_status: 429,
           retry_after: 75
         }}
    )

    assert {:snooze, 75} = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "queued"
  end

  test "final transient attempt terminalizes instead of exhausting queued work" do
    message = queued_message_fixture()
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    persisted_job = prepare_final_attempt!(message.id, submission.id, 7, 8)

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      test_pid: self(),
      result:
        {:error,
         %Provider.Error{
           class: :transient,
           code: "provider_unavailable",
           message: "provider is temporarily unavailable",
           http_status: 503
         }}
    )

    result = Oban.drain_queue(queue: :outbound)
    assert result.success == 1
    assert result.failure == 0
    assert result.discard == 0
    assert result.snoozed == 0

    assert_receive {:configured_provider_submit, _request}
    refute_receive {:configured_provider_submit, _request}

    failed_message = Repo.get!(OutboundMessage, message.id)
    assert failed_message.state == "failed"
    assert failed_message.last_error_class == "permanent"
    assert failed_message.last_error_code == "retry_exhausted"
    assert failed_message.last_error_message == "outbound submission retry limit was exhausted"
    assert %DateTime{} = failed_message.failed_at

    failed_submission = Repo.get!(ProviderSubmission, submission.id)
    assert failed_submission.state == "failed"
    assert failed_submission.attempt_count == 8
    assert failed_submission.last_error_code == "retry_exhausted"
    assert failed_submission.last_error_message == "outbound submission retry limit was exhausted"

    assert event_count(message.id, "submission_failed") == 1
    assert event_count(message.id, "submission_retryable") == 0
    assert Repo.aggregate(active_submit_jobs(message.id), :count) == 0

    assert %Oban.Job{state: "completed", attempt: 8, max_attempts: 8} =
             Repo.get!(Oban.Job, persisted_job.id)

    assert {:cancel, "submission_not_retryable"} =
             SubmitOutbound.perform(job(message.id, attempt: 8, max_attempts: 8))

    refute_receive {:configured_provider_submit, _request}
    assert event_count(message.id, "submission_failed") == 1
  end

  test "completes terminal failures after persisting failed state" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result:
        {:error,
         %Provider.Error{
           class: :permanent,
           code: "validation_error",
           message: "bad sender",
           http_status: 422
         }}
    )

    assert :ok = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "failed"
  end

  test "integrity failure completes once without credential or provider access" do
    message = microsoft_message_fixture()
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    request_payload = explicit_request_payload(submission.id)
    method = Repo.get!(SendMethod, submission.send_method_id)
    authorization = Repo.get!(OAuthAuthorization, method.oauth_authorization_id)

    authorization
    |> Ecto.Changeset.change(access_token_ciphertext: <<1, 2, 3>>)
    |> Repo.update!()

    reinsert_submission!(submission, request_sha256: String.duplicate("0", 64))

    result = Oban.drain_queue(queue: :outbound)
    assert result.success == 1
    assert result.failure == 0
    assert result.discard == 0

    failed_message = Repo.get!(OutboundMessage, message.id)
    assert failed_message.state == "failed"
    assert failed_message.last_error_code == "request_integrity_failed"
    assert %DateTime{} = failed_message.failed_at

    failed_submission = Repo.get!(ProviderSubmission, submission.id)
    assert failed_submission.state == "failed"
    assert failed_submission.attempt_count == 0
    assert failed_submission.first_attempt_at == nil
    assert failed_submission.last_attempt_at == nil
    assert explicit_request_payload(submission.id) == request_payload
    assert event_count(message.id, "submission_failed") == 1
    assert event_count(message.id, "submission_started") == 0
    assert Repo.aggregate(active_submit_jobs(message.id), :count) == 0

    assert {:cancel, "submission_not_retryable"} =
             SubmitOutbound.perform(job(message.id, attempt: 1, max_attempts: 8))

    assert event_count(message.id, "submission_failed") == 1
  end

  test "completes an uncertain submission and repeated execution never resends" do
    message = queued_message_fixture()

    Application.put_env(
      :manifold_outbound,
      :provider_config,
      result:
        {:error,
         %Provider.Error{
           class: :uncertain,
           code: "acceptance_unknown",
           message: "provider may have accepted"
         }}
    )

    assert :ok = SubmitOutbound.perform(job(message.id))
    assert Repo.get!(OutboundMessage, message.id).state == "submission_uncertain"
    assert Repo.get_by!(ProviderSubmission, outbound_message_id: message.id).state == "uncertain"

    assert :ok = SubmitOutbound.perform(job(message.id))

    assert Repo.aggregate(
             from(event in OutboundEvent,
               where:
                 event.outbound_message_id == ^message.id and
                   event.event_type == "submission_uncertain"
             ),
             :count
           ) == 1
  end

  test "Microsoft 5xx completes as uncertainty and leaves no retryable job" do
    configure_microsoft_req_test!()
    message = microsoft_message_fixture()

    Req.Test.expect(__MODULE__, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => %{"code" => "ServiceUnavailable"}})
    end)

    result = Oban.drain_queue(queue: :outbound)
    assert result.success == 1

    persisted = Repo.get!(OutboundMessage, message.id)
    assert persisted.state == "submission_uncertain"

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert submission.state == "uncertain"
    assert submission.last_error_code == "acceptance_unknown"

    assert Repo.aggregate(
             from(event in OutboundEvent,
               where:
                 event.outbound_message_id == ^message.id and
                   event.event_type == "submission_uncertain"
             ),
             :count
           ) == 1

    assert Repo.aggregate(active_submit_jobs(message.id), :count) == 0

    assert :ok = SubmitOutbound.perform(job(message.id))
    assert Repo.aggregate(active_submit_jobs(message.id), :count) == 0
  end

  test "Microsoft 429 schedules a byte-identical worker retry on the snapshotted method" do
    configure_microsoft_req_test!()
    message = microsoft_message_fixture()
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    payload = explicit_request_payload(submission.id)
    test_pid = self()
    original_job = Repo.one!(submit_jobs(message.id))

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, encoded, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:microsoft_worker_request, :first, encoded})

      conn
      |> Plug.Conn.put_resp_header("retry-after", "75")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"code" => "TooManyRequests"}})
    end)

    snooze_started_at = DateTime.utc_now()
    first_drain = Oban.drain_queue(queue: :outbound)
    snooze_finished_at = DateTime.utc_now()
    assert first_drain.snoozed == 1
    assert first_drain.success == 0

    assert_receive {:microsoft_worker_request, :first, first_encoded}
    assert Base.decode64!(first_encoded) == payload

    assert Repo.get!(OutboundMessage, message.id).state == "queued"
    assert Repo.get!(ProviderSubmission, submission.id).state == "pending"
    assert explicit_request_payload(submission.id) == payload

    assert [%Oban.Job{} = scheduled] = Repo.all(submit_jobs(message.id))
    assert scheduled.id == original_job.id
    assert scheduled.state == "scheduled"
    assert scheduled.attempt == 1
    assert scheduled.max_attempts == original_job.max_attempts + 1

    assert DateTime.compare(
             scheduled.scheduled_at,
             DateTime.add(snooze_started_at, 74, :second)
           ) in [:eq, :gt]

    assert DateTime.compare(
             scheduled.scheduled_at,
             DateTime.add(snooze_finished_at, 76, :second)
           ) in [:eq, :lt]

    assert scheduled.args == %{"outbound_message_id" => message.id}
    assert Repo.aggregate(active_submit_jobs(message.id), :count) == 1

    retryable =
      scheduled
      |> Ecto.Changeset.change(state: "available", scheduled_at: DateTime.utc_now())
      |> Repo.update!()

    assert retryable.id == scheduled.id
    assert retryable.state == "available"

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, encoded, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:microsoft_worker_request, :second, encoded})
      Plug.Conn.send_resp(conn, 202, "")
    end)

    second_drain = Oban.drain_queue(queue: :outbound)
    assert second_drain.success == 1
    assert second_drain.snoozed == 0

    assert_receive {:microsoft_worker_request, :second, second_encoded}
    assert second_encoded == first_encoded
    assert Base.decode64!(second_encoded) == payload

    accepted = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    assert accepted.state == "accepted"
    assert accepted.attempt_count == 2
    assert accepted.send_method_id == submission.send_method_id
    assert explicit_request_payload(accepted.id) == payload
    assert Repo.get!(OutboundMessage, message.id).state == "accepted_by_provider"
    assert Repo.aggregate(active_submit_jobs(message.id), :count) == 0

    assert [%Oban.Job{id: job_id, state: "completed"}] = Repo.all(submit_jobs(message.id))
    assert job_id == scheduled.id
  end

  test "application attempt ceiling terminalizes a final Microsoft 429 without snoozing" do
    configure_microsoft_req_test!()
    message = microsoft_message_fixture()
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)
    persisted_job = prepare_final_attempt!(message.id, submission.id, 7, 12)
    test_pid = self()

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, encoded, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:final_microsoft_request, encoded})

      conn
      |> Plug.Conn.put_resp_header("retry-after", "75")
      |> Plug.Conn.put_status(429)
      |> Req.Test.json(%{"error" => %{"code" => "TooManyRequests"}})
    end)

    result = Oban.drain_queue(queue: :outbound)
    assert result.success == 1
    assert result.snoozed == 0
    assert result.failure == 0
    assert result.discard == 0

    assert_receive {:final_microsoft_request, encoded}
    assert Base.decode64!(encoded) == explicit_request_payload(submission.id)

    failed_message = Repo.get!(OutboundMessage, message.id)
    assert failed_message.state == "failed"
    assert failed_message.last_error_code == "retry_exhausted"

    failed_submission = Repo.get!(ProviderSubmission, submission.id)
    assert failed_submission.state == "failed"
    assert failed_submission.attempt_count == 8
    assert failed_submission.last_error_code == "retry_exhausted"

    assert event_count(message.id, "submission_failed") == 1
    assert event_count(message.id, "submission_retryable") == 0
    assert Repo.aggregate(active_submit_jobs(message.id), :count) == 0

    assert %Oban.Job{state: "completed", attempt: 8, max_attempts: 12} =
             Repo.get!(Oban.Job, persisted_job.id)

    assert {:cancel, "submission_not_retryable"} =
             SubmitOutbound.perform(job(message.id, attempt: 8, max_attempts: 12))

    assert event_count(message.id, "submission_failed") == 1
  end

  test "malformed IDs and mismatched nonterminal state fail safely" do
    assert {:cancel, "outbound_not_found"} =
             SubmitOutbound.perform(job("not-a-uuid", attempt: 8, max_attempts: 8))

    assert {:error, %{class: :permanent, reason: :outbound_not_found}} =
             Outbound.submit_message("not-a-uuid")

    assert {:error, %{class: :permanent, reason: :outbound_not_found}} =
             Submission.finalize_retry_exhausted("not-a-uuid")

    message = queued_message_fixture()
    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: message.id)

    message
    |> Ecto.Changeset.change(state: "submitting")
    |> Repo.update!()

    submission
    |> Ecto.Changeset.change(state: "submitting")
    |> Repo.update!()

    assert {:error,
            %{class: :temporary, reason: :retry_exhaustion_lifecycle_failed, details: details}} =
             Submission.finalize_retry_exhausted(message.id)

    assert details == %{}
    assert Repo.get!(OutboundMessage, message.id).state == "submitting"
    assert Repo.get!(ProviderSubmission, submission.id).state == "submitting"
    assert event_count(message.id, "submission_failed") == 0
  end

  defp job(message_id, attrs \\ []) do
    struct!(Oban.Job, Keyword.merge([args: %{"outbound_message_id" => message_id}], attrs))
  end

  defp queued_message_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "worker#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})
    address = "inbox@#{domain.normalized_domain}"

    method =
      %SendMethod{}
      |> SendMethod.changeset(%{
        account_id: mailbox.id,
        kind: "smtp",
        email_address: address,
        status: "connected",
        enabled: true
      })
      |> Repo.insert!()

    {:ok, draft} =
      Outbound.create_draft(mailbox.id, %{
        subject: "Worker",
        text_body: "Body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)
    current = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)
    Repo.delete!(current)
    Repo.delete!(method)
    now = DateTime.utc_now()

    assert {1, nil} =
             Repo.insert_all(ProviderSubmission, [
               %{
                 id: current.id,
                 outbound_message_id: queued.id,
                 send_method_id: nil,
                 provider: "resend",
                 canonical_sender_address: queued.canonical_sender_address,
                 idempotency_key: current.idempotency_key,
                 request_sha256: LegacyResendFixture.request_sha256(queued),
                 request_payload: nil,
                 render_version: nil,
                 state: "pending",
                 attempt_count: 0,
                 provider_rfc_message_id: nil,
                 idempotency_expires_at: DateTime.add(now, 24, :hour),
                 provider_metadata: %{},
                 inserted_at: now,
                 updated_at: now
               }
             ])

    submission = Repo.get!(ProviderSubmission, current.id)

    assert Repo.get(SendMethod, method.id) == nil

    assert {:error, %{reason: :send_method_required}} =
             Connectors.checkout_send_method(method.id, queued.sender_address)

    assert %{
             send_method_id: nil,
             provider: "resend",
             provider_rfc_message_id: nil,
             idempotency_expires_at: %DateTime{}
           } = submission

    assert submission.request_sha256 == LegacyResendFixture.request_sha256(queued)
    queued
  end

  defp microsoft_message_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "worker-microsoft#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "sender"})
    address = "sender@#{domain.normalized_domain}"
    authorization_id = Ecto.UUID.generate()

    {:ok, access} =
      Crypto.encrypt("microsoft-worker-token", "credential:#{authorization_id}:access")

    {:ok, refresh} =
      Crypto.encrypt("microsoft-worker-refresh", "credential:#{authorization_id}:refresh")

    authorization =
      %OAuthAuthorization{id: authorization_id}
      |> OAuthAuthorization.changeset(%{
        account_id: mailbox.id,
        provider: "microsoft",
        provider_subject_id: "worker-subject-#{suffix}",
        email_address: address,
        granted_scopes: [MicrosoftScopes.send()],
        status: "connected",
        key_version: 1,
        access_token_ciphertext: access,
        refresh_token_ciphertext: refresh,
        token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })
      |> Repo.insert!()

    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: mailbox.id,
      oauth_authorization_id: authorization.id,
      kind: "microsoft",
      email_address: address,
      status: "connected",
      enabled: true
    })
    |> Repo.insert!()

    {:ok, draft} =
      Outbound.create_draft(mailbox.id, %{
        subject: "Worker Microsoft",
        text_body: "Persisted worker body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)
    queued
  end

  defp configure_microsoft_req_test! do
    previous = Application.get_env(:manifold_connectors, :providers, [])

    configured =
      Keyword.put(previous, :microsoft,
        base_url: "https://graph.microsoft.test/v1.0",
        req_options: [plug: {Req.Test, __MODULE__}]
      )

    Application.put_env(:manifold_connectors, :providers, configured)
    on_exit(fn -> Application.put_env(:manifold_connectors, :providers, previous) end)
  end

  defp explicit_request_payload(submission_id) do
    ProviderSubmission
    |> where([submission], submission.id == ^submission_id)
    |> select([submission], submission.request_payload)
    |> Repo.one!()
  end

  defp prepare_final_attempt!(message_id, submission_id, completed_attempts, max_attempts) do
    submission = Repo.get!(ProviderSubmission, submission_id)

    submission
    |> Ecto.Changeset.change(attempt_count: completed_attempts)
    |> Repo.update!()

    message_id
    |> submit_jobs()
    |> Repo.one!()
    |> Ecto.Changeset.change(
      attempt: completed_attempts,
      max_attempts: max_attempts,
      state: "available",
      scheduled_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  defp reinsert_submission!(submission, attrs) do
    row =
      submission
      |> Map.from_struct()
      |> Map.take(ProviderSubmission.__schema__(:fields))
      |> Map.put(:request_payload, explicit_request_payload(submission.id))
      |> Map.merge(Map.new(attrs))

    Repo.delete!(submission)
    assert {1, nil} = Repo.insert_all(ProviderSubmission, [row])
    Repo.get!(ProviderSubmission, submission.id)
  end

  defp event_count(message_id, event_type) do
    Repo.aggregate(
      from(event in OutboundEvent,
        where: event.outbound_message_id == ^message_id and event.event_type == ^event_type
      ),
      :count
    )
  end

  defp active_submit_jobs(message_id) do
    submit_jobs(message_id)
    |> where([job], job.state in ~w(available scheduled retryable))
  end

  defp submit_jobs(message_id) do
    from(job in Oban.Job,
      where:
        job.worker == ^inspect(SubmitOutbound) and
          fragment("?->>'outbound_message_id' = ?", job.args, ^message_id)
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_outbound, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_outbound, key, value)
end

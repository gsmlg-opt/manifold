defmodule Manifold.OutboundTest do
  use Manifold.DataCase, async: false

  import ExUnit.CaptureLog

  alias Manifold.Accounts
  alias Manifold.Connectors.Schema.SendMethod
  alias Manifold.Outbound
  alias Manifold.Outbound.Jobs.SubmitOutbound
  alias Manifold.Outbound.Provider.Envelope
  alias Manifold.Outbound.RfcMessage

  alias Manifold.Outbound.Schema.{
    OutboundEvent,
    OutboundMessage,
    OutboundRecipient,
    ProviderEvent,
    ProviderSubmission
  }

  alias Manifold.Repo

  test "creates and updates an editable draft with frozen sender and recipients" do
    %{mailbox: mailbox, address: sender_address} = mailbox_fixture()

    assert {:ok, draft} =
             Outbound.create_draft(mailbox.id, %{
               subject: "Draft subject",
               text_body: "Draft body",
               recipients: [
                 %{kind: "to", address: "First@Example.net", name: "First"},
                 %{kind: "cc", address: "copy@example.net"}
               ]
             })

    assert draft.state == "draft"
    assert draft.sender_address == sender_address
    assert draft.subject == "Draft subject"

    assert Repo.get_by!(OutboundEvent, outbound_message_id: draft.id).event_type ==
             "draft_created"

    assert [
             %{kind: "to", address: "First@Example.net", canonical_address: "first@example.net"},
             %{kind: "cc", address: "copy@example.net", canonical_address: "copy@example.net"}
           ] = Outbound.list_recipients(draft.id)

    assert {:ok, updated} =
             Outbound.update_draft(
               mailbox.id,
               draft.id,
               %{
                 subject: "Updated",
                 text_body: "Changed",
                 recipients: [%{kind: "to", address: "replacement@example.net"}]
               },
               expected_revision: draft.lock_version
             )

    assert updated.subject == "Updated"
    assert updated.text_body == "Changed"
    assert [%{address: "replacement@example.net"}] = Outbound.list_recipients(draft.id)

    assert {:error, %{reason: :stale_draft}} =
             Outbound.update_draft(
               mailbox.id,
               draft.id,
               %{subject: "Stale"},
               expected_revision: draft.lock_version
             )
  end

  test "queueing freezes the draft and inserts exactly one Oban job transactionally" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    method = send_method_fixture(mailbox.id, address, "gmail")
    draft = draft_fixture(mailbox.id, include_bcc: true)

    assert {:ok, queued} =
             Outbound.queue_draft(mailbox.id, draft.id, expected_revision: draft.lock_version)

    assert queued.state == "queued"
    assert %DateTime{} = queued.queued_at

    assert %Oban.Job{
             worker: worker,
             args: %{"outbound_message_id" => outbound_message_id}
           } = Repo.one!(jobs_for(draft.id))

    assert worker == inspect(SubmitOutbound)
    assert outbound_message_id == draft.id

    assert %ProviderSubmission{
             outbound_message_id: ^outbound_message_id,
             send_method_id: send_method_id,
             provider: "gmail",
             canonical_sender_address: canonical_sender_address,
             render_version: 1,
             request_payload: nil,
             state: "pending",
             idempotency_key: idempotency_key,
             request_sha256: request_sha256,
             provider_rfc_message_id: provider_rfc_message_id,
             idempotency_expires_at: nil
           } = Repo.one!(submissions_for(draft.id))

    assert send_method_id == method.id
    assert canonical_sender_address == queued.canonical_sender_address
    assert provider_rfc_message_id == "<#{queued.id}@manifold.local>"
    assert byte_size(idempotency_key) > 0
    expected_raw = expected_raw(queued, "gmail", idempotency_key)
    request_payload = explicit_request_payload(outbound_message_id)
    assert is_binary(request_payload)
    assert expected_raw =~ "Bcc: hidden@example.net\r\n"
    assert request_payload == expected_raw
    assert request_sha256 == sha256(expected_raw)
    assert Repo.get_by!(OutboundEvent, outbound_message_id: draft.id, event_type: "queued")

    assert {:ok, repeated} = Outbound.queue_draft(mailbox.id, draft.id)
    assert repeated.id == draft.id
    assert Repo.aggregate(jobs_for(draft.id), :count) == 1
    assert Repo.aggregate(submissions_for(draft.id), :count) == 1

    assert {:error, %{reason: :message_not_editable}} =
             Outbound.update_draft(mailbox.id, draft.id, %{subject: "Too late"})
  end

  test "queue transaction failure rolls back state and job insertion" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")
    draft = draft_fixture(mailbox.id)

    assert {:error, %{reason: :after_queue_before_job}} =
             Outbound.queue_draft(mailbox.id, draft.id, fail_at: :after_queue_before_job)

    assert Repo.get!(OutboundMessage, draft.id).state == "draft"
    assert Repo.aggregate(jobs_for(draft.id), :count) == 0
    assert Repo.aggregate(submissions_for(draft.id), :count) == 0
  end

  test "queueing rechecks and locks the active sender before the draft" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")
    draft = draft_fixture(mailbox.id)

    {result, queries} =
      capture_repo_queries(fn ->
        Outbound.queue_draft(mailbox.id, draft.id, expected_revision: draft.lock_version)
      end)

    assert {:ok, %OutboundMessage{state: "queued"}} = result

    lock_queries = Enum.filter(queries, &String.contains?(&1, "FOR UPDATE"))
    assert [sender_lock, draft_lock | _additional_locks] = lock_queries
    assert String.contains?(sender_lock, ~s(FROM "mailboxes"))
    assert String.contains?(draft_lock, ~s(FROM "outbound_messages"))
  end

  test "inactive sender cannot queue an existing draft" do
    %{mailbox: mailbox} = mailbox_fixture()
    draft = draft_fixture(mailbox.id)

    assert {:ok, _mailbox} = Accounts.disable_account(mailbox.id)

    assert {:error, %{class: :permanent, reason: :sender_not_active}} =
             Outbound.queue_draft(mailbox.id, draft.id, expected_revision: draft.lock_version)

    assert Repo.get!(OutboundMessage, draft.id).state == "draft"
    refute Repo.get_by(ProviderSubmission, outbound_message_id: draft.id)

    refute Repo.get_by(Oban.Job,
             worker: inspect(SubmitOutbound),
             args: %{"outbound_message_id" => draft.id}
           )
  end

  test "draft creation rechecks sender activity immediately before persistence" do
    %{mailbox: mailbox} = mailbox_fixture()

    before_persist = fn ->
      assert {:ok, _mailbox} = Accounts.disable_account(mailbox.id)
    end

    assert {:error, %{class: :permanent, reason: :sender_not_active}} =
             Outbound.create_draft(
               mailbox.id,
               %{
                 subject: "Stale create",
                 text_body: "Body",
                 recipients: [%{kind: "to", address: "person@example.net"}]
               },
               before_persist: before_persist
             )

    assert Repo.aggregate(
             from(message in OutboundMessage, where: message.mailbox_id == ^mailbox.id),
             :count
           ) == 0

    assert Repo.aggregate(
             from(recipient in OutboundRecipient,
               join: message in OutboundMessage,
               on: message.id == recipient.outbound_message_id,
               where: message.mailbox_id == ^mailbox.id
             ),
             :count
           ) == 0

    assert Repo.aggregate(
             from(event in OutboundEvent,
               join: message in OutboundMessage,
               on: message.id == event.outbound_message_id,
               where: message.mailbox_id == ^mailbox.id
             ),
             :count
           ) == 0
  end

  test "draft creation freezes sender fields from the locked current account" do
    %{mailbox: mailbox, address: original_address} = mailbox_fixture()
    [_local_part, domain] = String.split(original_address, "@", parts: 2)

    before_persist = fn ->
      assert {:ok, updated} =
               Accounts.update_account(mailbox, %{
                 name: "Current Sender",
                 address: "current@#{domain}"
               })

      assert updated.local_part == "current"
    end

    assert {:ok, draft} =
             Outbound.create_draft(
               mailbox.id,
               %{
                 subject: "Current identity",
                 text_body: "Body",
                 recipients: [%{kind: "to", address: "person@example.net"}]
               },
               before_persist: before_persist
             )

    assert draft.sender_name == "Current Sender"
    assert draft.sender_address == "current@#{domain}"
    assert draft.canonical_sender_address == "current@#{domain}"
  end

  test "draft update rechecks sender activity immediately before persistence" do
    %{mailbox: mailbox} = mailbox_fixture()
    draft = draft_fixture(mailbox.id)

    before_persist = fn ->
      assert {:ok, _mailbox} = Accounts.disable_account(mailbox.id)
    end

    assert {:error, %{class: :permanent, reason: :sender_not_active}} =
             Outbound.update_draft(
               mailbox.id,
               draft.id,
               %{
                 subject: "Stale update",
                 recipients: [%{kind: "to", address: "changed@example.net"}]
               },
               expected_revision: draft.lock_version,
               before_persist: before_persist
             )

    assert Repo.get!(OutboundMessage, draft.id).subject == "Ready"
    assert [%{address: "person@example.net"}] = Outbound.list_recipients(draft.id)
  end

  test "account job cancellation is bounded and preserves unrelated jobs" do
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})

    %{mailbox: mailbox, address: address} = mailbox_fixture()
    %{mailbox: other_mailbox, address: other_address} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")
    send_method_fixture(other_mailbox.id, other_address, "smtp")

    target_messages =
      for _index <- 1..4 do
        draft = draft_fixture(mailbox.id)
        assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)
        queued
      end

    other_draft = draft_fixture(other_mailbox.id)
    assert {:ok, other_message} = Outbound.queue_draft(other_mailbox.id, other_draft.id)

    target_jobs =
      Oban.Job
      |> where([job], job.worker == ^inspect(SubmitOutbound))
      |> where(
        [job],
        fragment("?->>'outbound_message_id'", job.args) in ^Enum.map(target_messages, & &1.id)
      )
      |> order_by([job], asc: job.id)
      |> Repo.all()

    [suspended, _available, pending_execution, completed] = target_jobs

    Oban.Job
    |> where([job], job.id == ^suspended.id)
    |> Repo.update_all(set: [state: "suspended"])

    Oban.Job
    |> where([job], job.id == ^completed.id)
    |> Repo.update_all(set: [state: "completed"])

    unrelated =
      %{outbound_message_id: hd(target_messages).id}
      |> Oban.Job.new(worker: "Manifold.UnrelatedWorker", queue: :outbound)
      |> Repo.insert!()

    malformed =
      %{"outbound_message_id" => "not-a-uuid"}
      |> SubmitOutbound.new()
      |> Repo.insert!()

    assert target_incomplete_job_count(mailbox.id) == 3

    assert %{cancelled: 2, done?: false} = Outbound.cancel_account_jobs(mailbox.id, 2)
    assert target_incomplete_job_count(mailbox.id) == 1
    assert target_cancelled_job_count(mailbox.id) == 2

    Oban.Job
    |> where([job], job.id == ^pending_execution.id)
    |> Repo.update_all(set: [state: "executing"])

    assert {:snooze, 5} = Outbound.cancel_account_jobs(mailbox.id, 2)
    assert target_incomplete_job_count(mailbox.id) == 0
    assert target_cancelled_job_count(mailbox.id) == 3

    assert %{cancelled: 0, done?: true} = Outbound.cancel_account_jobs(mailbox.id, 2)

    assert Repo.get!(Oban.Job, completed.id).state == "completed"
    assert Repo.get!(Oban.Job, unrelated.id).state == "available"
    assert Repo.get!(Oban.Job, malformed.id).state == "available"

    assert Repo.get_by!(Oban.Job,
             worker: inspect(SubmitOutbound),
             args: %{"outbound_message_id" => other_message.id}
           ).state == "available"
  end

  test "account job cancellation keeps bounded ownership selection in SQL" do
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})

    %{mailbox: mailbox, address: address} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")

    for _index <- 1..25 do
      draft = draft_fixture(mailbox.id)
      assert {:ok, _queued} = Outbound.queue_draft(mailbox.id, draft.id)
    end

    %{"outbound_message_id" => "not-a-uuid"}
    |> SubmitOutbound.new()
    |> Repo.insert!()

    {_result, queries} =
      capture_repo_queries(fn -> Outbound.cancel_account_jobs(mailbox.id, 1) end)

    ownership_query =
      Enum.find(queries, fn query ->
        String.starts_with?(query, "SELECT ") and
          String.contains?(query, ~s("oban_jobs")) and
          String.contains?(query, ~s("outbound_messages")) and
          String.contains?(query, "ORDER BY") and
          String.contains?(query, "LIMIT $")
      end)

    assert is_binary(ownership_query)
    assert String.contains?(ownership_query, "EXISTS")
    assert String.contains?(ownership_query, "CASE")
    assert String.contains?(ownership_query, "~*")
    assert String.contains?(ownership_query, "::uuid")
    refute String.contains?(ownership_query, ~s("id"::text))
  end

  test "account job cancellation locks selected jobs across state transitions" do
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})

    {:ok, race_repo} =
      Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 3)

    Process.unlink(race_repo)

    %{domain: domain, mailbox: mailbox, message: message, job: job} =
      on_repo(race_repo, fn ->
        {:ok, domain} =
          Accounts.create_domain(%{name: "outbound-race-#{Ecto.UUID.generate()}.test"})

        {:ok, mailbox} =
          Accounts.create_account(domain, %{local_part: "inbox", name: "Race Sender"})

        send_method_fixture(mailbox.id, "inbox@#{domain.normalized_domain}", "gmail")
        draft = draft_fixture(mailbox.id)
        assert {:ok, message} = Outbound.queue_draft(mailbox.id, draft.id)

        job =
          Repo.get_by!(Oban.Job,
            worker: inspect(SubmitOutbound),
            args: %{"outbound_message_id" => message.id}
          )

        %{domain: domain, mailbox: mailbox, message: message, job: job}
      end)

    on_exit(fn ->
      cleanup_race_fixture(race_repo, job.id, message.id, mailbox.id, domain.id)
    end)

    event = Keyword.fetch!(Repo.config(), :telemetry_prefix) ++ [:query]
    handler_id = {__MODULE__, self(), make_ref()}
    barrier_ref = make_ref()

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, %{query: query}, {test_pid, ref} ->
          if selected_job_query?(query) do
            send(test_pid, {:selected_jobs, self(), ref, query})

            receive do
              {:resume_cancellation, ^ref} -> :ok
            after
              5_000 -> :ok
            end
          end
        end,
        {self(), barrier_ref}
      )

    cancel_task =
      Task.async(fn ->
        on_repo(race_repo, fn -> Outbound.cancel_account_jobs(mailbox.id, 1) end)
      end)

    {transition_yield, cancel_result, transition_result} =
      try do
        assert_receive {:selected_jobs, cancel_pid, ^barrier_ref, selected_query}, 2_000
        assert String.contains?(selected_query, "LIMIT $")

        transition_task =
          Task.async(fn ->
            on_repo(race_repo, fn ->
              Oban.Job
              |> where([candidate], candidate.id == ^job.id and candidate.state == "available")
              |> Repo.update_all(set: [state: "executing"])
            end)
          end)

        transition_yield = Task.yield(transition_task, 200)
        send(cancel_pid, {:resume_cancellation, barrier_ref})

        cancel_result = Task.await(cancel_task, 5_000)

        transition_result =
          case transition_yield do
            nil -> Task.await(transition_task, 5_000)
            {:ok, result} -> result
          end

        {transition_yield, cancel_result, transition_result}
      after
        send(cancel_task.pid, {:resume_cancellation, barrier_ref})
        :telemetry.detach(handler_id)
      end

    assert is_nil(transition_yield)
    assert %{cancelled: 1, done?: true} = cancel_result
    assert {0, nil} = transition_result

    assert on_repo(race_repo, fn -> Repo.get!(Oban.Job, job.id).state end) == "cancelled"
    assert on_repo(race_repo, fn -> Repo.get!(OutboundMessage, message.id).id end) == message.id

    cleanup_race_fixture(race_repo, job.id, message.id, mailbox.id, domain.id)
  end

  test "outbound purge index supports bounded mailbox ID scans" do
    %{mailbox: mailbox} = mailbox_fixture()
    _draft = draft_fixture(mailbox.id)

    index_name = "outbound_messages_mailbox_id_id_index"

    assert [[^index_name, index_definition]] =
             Repo.query!(
               """
               SELECT indexname, indexdef
               FROM pg_indexes
               WHERE schemaname = current_schema()
                 AND tablename = 'outbound_messages'
                 AND indexname = $1
               """,
               [index_name]
             ).rows

    assert index_definition =~ "(mailbox_id, id)"

    Repo.query!("SET LOCAL enable_seqscan = off")

    plan =
      Repo.query!(
        """
        EXPLAIN (COSTS OFF)
        SELECT id
        FROM outbound_messages
        WHERE mailbox_id = $1
        ORDER BY id
        LIMIT 250
        """,
        [Ecto.UUID.dump!(mailbox.id)]
      ).rows
      |> List.flatten()
      |> Enum.join("\n")

    assert plan =~ index_name
  end

  test "outbound purge index is built concurrently outside migration locks" do
    migration_path =
      Path.expand(
        "../../../manifold_data/priv/repo/migrations/20260811000200_add_outbound_purge_index.exs",
        __DIR__
      )

    assert File.exists?(migration_path)
    migration = Manifold.Repo.Migrations.AddOutboundPurgeIndex
    unless Code.ensure_loaded?(migration), do: Code.require_file(migration_path)

    assert [disable_ddl_transaction: true, disable_migration_lock: true] =
             apply(migration, :__migration__, [])

    source = File.read!(migration_path)
    assert source =~ "index(:outbound_messages, [:mailbox_id, :id], concurrently: true)"
    assert length(Regex.scan(~r/concurrently:\s*true/, source)) == 1
  end

  test "account purge deletes bounded messages and provider events before cascades" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    %{mailbox: other_mailbox, address: other_address} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")
    send_method_fixture(other_mailbox.id, other_address, "smtp")

    target_messages =
      for _index <- 1..3 do
        draft = draft_fixture(mailbox.id)
        assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)
        insert_provider_event(queued.id)
        queued
      end

    other_draft = draft_fixture(other_mailbox.id)
    assert {:ok, other_message} = Outbound.queue_draft(other_mailbox.id, other_draft.id)
    other_provider_event = insert_provider_event(other_message.id)

    assert Outbound.account_data_remaining?(mailbox.id)

    selected_ids =
      target_messages
      |> Enum.map(& &1.id)
      |> Enum.sort()
      |> Enum.take(2)

    {first_result, queries} =
      capture_repo_queries(fn -> Outbound.purge_account_batch(mailbox.id, 2) end)

    assert %{deleted: 2, done?: false} = first_result

    provider_delete_index =
      Enum.find_index(queries, &String.contains?(&1, ~s(DELETE FROM "provider_events")))

    message_delete_index =
      Enum.find_index(queries, &String.contains?(&1, ~s(DELETE FROM "outbound_messages")))

    assert is_integer(provider_delete_index)
    assert is_integer(message_delete_index)
    assert provider_delete_index < message_delete_index

    Enum.each(selected_ids, fn message_id ->
      refute Repo.get(OutboundMessage, message_id)
      refute Repo.get_by(ProviderEvent, outbound_message_id: message_id)
      refute Repo.get_by(ProviderSubmission, outbound_message_id: message_id)

      assert Repo.aggregate(
               from(recipient in OutboundRecipient,
                 where: recipient.outbound_message_id == ^message_id
               ),
               :count
             ) == 0

      assert Repo.aggregate(
               from(event in OutboundEvent, where: event.outbound_message_id == ^message_id),
               :count
             ) == 0
    end)

    assert Repo.aggregate(
             from(message in OutboundMessage, where: message.mailbox_id == ^mailbox.id),
             :count
           ) == 1

    assert %{deleted: 1, done?: true} = Outbound.purge_account_batch(mailbox.id, 2)
    assert %{deleted: 0, done?: true} = Outbound.purge_account_batch(mailbox.id, 2)
    refute Outbound.account_data_remaining?(mailbox.id)

    assert Repo.get!(OutboundMessage, other_message.id)

    assert Repo.get!(ProviderEvent, other_provider_event.id).outbound_message_id ==
             other_message.id

    assert Repo.get_by!(ProviderSubmission, outbound_message_id: other_message.id)
    assert Outbound.account_data_remaining?(other_mailbox.id)
  end

  test "queueing without an operational send method leaves the draft unchanged" do
    %{mailbox: mailbox} = mailbox_fixture()

    {:ok, draft} =
      Outbound.create_draft(mailbox.id, %{
        subject: "Selection failure",
        text_body: "send-method-selection-secret-body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    handler_id = "send-method-selection-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :outbound, :send_method, :select, :stop],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, %{class: :permanent, reason: :send_method_required}} =
             Outbound.queue_draft(mailbox.id, draft.id)

    assert_receive {:telemetry, [:manifold, :outbound, :send_method, :select, :stop],
                    %{duration_ms: duration_ms, attempt_count: 1} = measurements,
                    %{
                      account_id: account_id,
                      outbound_message_id: outbound_message_id,
                      outcome: :error,
                      error_code: :send_method_required
                    } = metadata}

    assert is_integer(duration_ms) and duration_ms >= 0
    assert account_id == mailbox.id
    assert outbound_message_id == draft.id

    assert_secret_free_telemetry(measurements, metadata, [
      "send-method-selection-secret-body"
    ])

    assert Repo.get!(OutboundMessage, draft.id).state == "draft"
    assert Repo.aggregate(jobs_for(draft.id), :count) == 0
    assert Repo.aggregate(submissions_for(draft.id), :count) == 0
  end

  test "queueing snapshots SMTP bytes without a Bcc header" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    method = send_method_fixture(mailbox.id, address, "smtp")
    draft = draft_fixture(mailbox.id, include_bcc: true)

    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)
    expected_raw = expected_raw(queued, "smtp", submission.idempotency_key)

    assert submission.send_method_id == method.id
    assert submission.provider == "smtp"
    assert submission.canonical_sender_address == queued.canonical_sender_address
    assert submission.render_version == 1
    assert submission.request_payload == nil
    assert explicit_request_payload(submission.id) == expected_raw
    assert submission.provider_rfc_message_id == "<#{queued.id}@manifold.local>"
    assert submission.idempotency_expires_at == nil
    refute expected_raw =~ "Bcc:"
    assert submission.request_sha256 == sha256(expected_raw)
  end

  test "queueing snapshots exact Microsoft MIME without copying it into the job" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    method = send_method_fixture(mailbox.id, address, "microsoft")

    {:ok, draft} =
      Outbound.create_draft(mailbox.id, %{
        subject: "Microsoft snapshot",
        text_body: "Private body",
        recipients: [
          %{kind: "to", address: "person@example.net"},
          %{kind: "bcc", address: "blind@example.net"}
        ]
      })

    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)
    assert submission.provider == "microsoft"
    assert submission.send_method_id == method.id
    assert submission.canonical_sender_address == queued.canonical_sender_address
    assert submission.render_version == 1
    assert submission.request_payload == nil
    request_payload = explicit_request_payload(submission.id)
    assert sha256(request_payload) == submission.request_sha256
    assert request_payload =~ "Bcc: blind@example.net\r\n"
    assert submission.provider_rfc_message_id == "<#{queued.id}@manifold.local>"

    assert [%Oban.Job{args: args}] = Repo.all(jobs_for(queued.id))
    assert args == %{"outbound_message_id" => queued.id}
    refute inspect(args) =~ "blind@example.net"
    refute inspect(args) =~ "Private body"

    queued_event =
      Repo.get_by!(OutboundEvent, outbound_message_id: queued.id, event_type: "queued")

    refute inspect(queued_event) =~ "blind@example.net"
    refute inspect(queued_event) =~ "Private body"
  end

  test "provider snapshot insertion emits neither MIME query telemetry nor debug logs" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "microsoft")
    secret_body = "telemetry-private-body-#{System.unique_integer([:positive])}"
    secret_bcc = "telemetry-private-bcc@example.net"

    {:ok, draft} =
      Outbound.create_draft(mailbox.id, %{
        subject: "Telemetry-safe snapshot",
        text_body: secret_body,
        recipients: [
          %{kind: "to", address: "person@example.net"},
          %{kind: "bcc", address: secret_bcc}
        ]
      })

    handler_id = {__MODULE__, self(), make_ref()}
    event = Keyword.fetch!(Repo.config(), :telemetry_prefix) ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, pid -> send(pid, {:repo_metadata, metadata}) end,
        self()
      )

    log =
      try do
        capture_log([level: :debug], fn ->
          assert {:ok, _queued} = Outbound.queue_draft(mailbox.id, draft.id)
        end)
      after
        :telemetry.detach(handler_id)
      end

    metadata = collect_repo_metadata([])

    provider_insert_metadata =
      Enum.filter(metadata, fn entry ->
        String.contains?(entry.query, ~s(INSERT INTO "provider_submissions"))
      end)

    assert provider_insert_metadata == []

    for inspected <- [log | Enum.map(provider_insert_metadata, &inspect/1)] do
      refute inspected =~ secret_body
      refute inspected =~ secret_bcc
    end

    submission = Repo.get_by!(ProviderSubmission, outbound_message_id: draft.id)
    assert explicit_request_payload(submission.id) =~ secret_body
  end

  test "provider payload migration uses staged validation and an immutable snapshot trigger" do
    migration_path =
      Path.expand(
        "../../../manifold_data/priv/repo/migrations/20260812000300_add_microsoft_provider_payloads.exs",
        __DIR__
      )

    migration = Manifold.Repo.Migrations.AddMicrosoftProviderPayloads
    unless Code.ensure_loaded?(migration), do: Code.require_file(migration_path)

    assert apply(migration, :__migration__, [])[:disable_ddl_transaction]

    source = File.read!(migration_path)
    assert source =~ "@backfill_batch_size 500"
    assert source =~ ~S(LIMIT #{@backfill_batch_size})
    assert source =~ "NOT VALID"
    assert source =~ "VALIDATE CONSTRAINT"
    assert source =~ "provider_submissions_snapshot_immutable"
    assert source =~ "CREATE TRIGGER provider_submissions_freeze_snapshot"
  end

  test "queueing rejects a draft sender that differs from the selected method" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")

    draft =
      mailbox.id
      |> draft_fixture()
      |> Ecto.Changeset.change(
        sender_address: "other@example.test",
        canonical_sender_address: "other@example.test"
      )
      |> Repo.update!()

    assert {:error, %{class: :permanent, reason: :sender_address_mismatch}} =
             Outbound.queue_draft(mailbox.id, draft.id)

    assert Repo.get!(OutboundMessage, draft.id).state == "draft"
    assert Repo.aggregate(jobs_for(draft.id), :count) == 0
    assert Repo.aggregate(submissions_for(draft.id), :count) == 0
  end

  test "an already queued message keeps its method snapshot after the enabled method changes" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    gmail = send_method_fixture(mailbox.id, address, "gmail")
    draft = draft_fixture(mailbox.id)

    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)
    original = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)

    gmail |> SendMethod.changeset(%{enabled: false}) |> Repo.update!()
    smtp = send_method_fixture(mailbox.id, address, "smtp")

    assert {:ok, repeated} = Outbound.queue_draft(mailbox.id, draft.id)
    assert repeated.id == queued.id

    persisted = Repo.get!(ProviderSubmission, original.id)
    assert persisted.send_method_id == gmail.id
    refute persisted.send_method_id == smtp.id
    assert persisted.provider == "gmail"
    assert persisted.request_sha256 == original.request_sha256
    assert persisted.provider_rfc_message_id == original.provider_rfc_message_id
    assert Repo.aggregate(submissions_for(draft.id), :count) == 1
    assert Repo.aggregate(jobs_for(draft.id), :count) == 1
  end

  test "rejects invalid or duplicate recipient addresses" do
    %{mailbox: mailbox} = mailbox_fixture()

    assert {:error, %{reason: :invalid_recipient}} =
             Outbound.create_draft(mailbox.id, %{
               subject: "Invalid",
               text_body: "Body",
               recipients: [%{kind: "to", address: "not-an-address"}]
             })

    assert {:error, %{reason: :duplicate_recipient}} =
             Outbound.create_draft(mailbox.id, %{
               subject: "Duplicate",
               text_body: "Body",
               recipients: [
                 %{kind: "to", address: "person@example.net"},
                 %{kind: "cc", address: "PERSON@example.net"}
               ]
             })

    mailbox_messages =
      from(message in OutboundMessage, where: message.mailbox_id == ^mailbox.id)

    mailbox_recipients =
      from(recipient in OutboundRecipient,
        join: message in OutboundMessage,
        on: message.id == recipient.outbound_message_id,
        where: message.mailbox_id == ^mailbox.id
      )

    assert Repo.aggregate(mailbox_messages, :count) == 0
    assert Repo.aggregate(mailbox_recipients, :count) == 0
  end

  test "inactive mailbox cannot create an outbound draft" do
    %{mailbox: mailbox} = mailbox_fixture()

    mailbox
    |> Ecto.Changeset.change(active: false)
    |> Repo.update!()

    assert {:error, %{reason: :sender_not_active}} =
             Outbound.create_draft(mailbox.id, %{
               subject: "No send",
               text_body: "Body",
               recipients: [%{kind: "to", address: "person@example.net"}]
             })
  end

  test "draft identifiers remain mailbox scoped" do
    %{mailbox: first_mailbox} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()
    draft = draft_fixture(first_mailbox.id)

    assert {:error, %{reason: :draft_not_found}} =
             Outbound.update_draft(other_mailbox.id, draft.id, %{subject: "Cross mailbox"})

    assert {:error, %{reason: :draft_not_found}} =
             Outbound.queue_draft(other_mailbox.id, draft.id)
  end

  test "lists and deletes drafts within one mailbox" do
    %{mailbox: mailbox} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()
    first = draft_fixture(mailbox.id)
    second = draft_fixture(mailbox.id)
    _other = draft_fixture(other_mailbox.id)

    assert [listed_second, listed_first] = Outbound.list_drafts(mailbox.id)
    assert listed_second.id == second.id
    assert listed_first.id == first.id

    assert {:ok, deleted} = Outbound.delete_draft(mailbox.id, first.id)
    assert deleted.id == first.id
    assert [remaining] = Outbound.list_drafts(mailbox.id)
    assert remaining.id == second.id

    assert {:error, %{reason: :draft_not_found}} =
             Outbound.delete_draft(other_mailbox.id, second.id)
  end

  test "sent list excludes drafts and remains mailbox scoped" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    %{mailbox: other_mailbox, address: other_address} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")
    send_method_fixture(other_mailbox.id, other_address, "smtp")
    draft = draft_fixture(mailbox.id)
    queued = draft_fixture(mailbox.id)
    other_queued = draft_fixture(other_mailbox.id)

    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, queued.id)
    assert {:ok, _other} = Outbound.queue_draft(other_mailbox.id, other_queued.id)

    assert [summary] = Outbound.list_sent(mailbox.id)
    assert summary.id == queued.id
    assert summary.state == "queued"
    assert summary.recipients == ["person@example.net"]
    refute summary.id == draft.id
  end

  test "loads mailbox-scoped draft details through a public projection" do
    %{mailbox: mailbox, address: sender_address} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()

    draft =
      draft_fixture(mailbox.id)

    assert {:ok, detail} = Outbound.get_draft(mailbox.id, draft.id)
    assert detail.id == draft.id
    assert detail.sender_address == sender_address
    assert detail.subject == "Ready"
    assert detail.text_body == "Body"
    assert detail.lock_version == draft.lock_version
    assert [%{kind: "to", address: "person@example.net"}] = detail.recipients

    assert {:error, %{reason: :draft_not_found}} =
             Outbound.get_draft(other_mailbox.id, draft.id)
  end

  test "loads sent detail with recipient, submission, and audit projections" do
    %{mailbox: mailbox, address: address} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()
    send_method_fixture(mailbox.id, address, "gmail")
    draft = draft_fixture(mailbox.id)
    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)

    assert {:ok, detail} = Outbound.get_sent(mailbox.id, queued.id)
    assert detail.id == queued.id
    assert detail.state == "queued"
    assert detail.subject == "Ready"
    assert [%{kind: "to", delivery_state: "pending"}] = detail.recipients
    assert detail.submission.provider == "gmail"
    assert detail.submission.state == "pending"
    assert Enum.map(detail.events, & &1.event_type) == ["draft_created", "queued"]

    assert {:error, %{reason: :sent_not_found}} =
             Outbound.get_sent(other_mailbox.id, queued.id)

    assert {:error, %{reason: :sent_not_found}} =
             Outbound.get_sent(mailbox.id, draft_fixture(mailbox.id).id)
  end

  defp draft_fixture(mailbox_id, opts \\ []) do
    recipients =
      [%{kind: "to", address: "person@example.net"}] ++
        if Keyword.get(opts, :include_bcc, false) do
          [%{kind: "bcc", address: "hidden@example.net"}]
        else
          []
        end

    {:ok, draft} =
      Outbound.create_draft(mailbox_id, %{
        subject: "Ready",
        text_body: "Body",
        recipients: recipients
      })

    draft
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "outbound#{suffix}.test"})

    {:ok, mailbox} =
      Accounts.create_account(domain, %{local_part: "inbox", name: "Local Inbox"})

    %{domain: domain, mailbox: mailbox, address: "inbox@#{domain.normalized_domain}"}
  end

  defp on_repo(repo, fun) do
    previous_repo = Repo.put_dynamic_repo(repo)

    try do
      fun.()
    after
      Repo.put_dynamic_repo(previous_repo)
    end
  end

  defp cleanup_race_fixture(repo, job_id, message_id, mailbox_id, domain_id) do
    if Process.alive?(repo) do
      try do
        on_repo(repo, fn ->
          Oban.Job
          |> where([candidate], candidate.id == ^job_id)
          |> Repo.delete_all()

          Repo.query!("DELETE FROM outbound_messages WHERE id = $1", [
            Ecto.UUID.dump!(message_id)
          ])

          Repo.query!("DELETE FROM mailboxes WHERE id = $1", [Ecto.UUID.dump!(mailbox_id)])
          Repo.query!("DELETE FROM domains WHERE id = $1", [Ecto.UUID.dump!(domain_id)])
        end)
      after
        if Process.alive?(repo) do
          try do
            Supervisor.stop(repo)
          catch
            :exit, _reason -> :ok
          end
        end
      end
    end
  end

  defp selected_job_query?(query) do
    String.starts_with?(query, "SELECT ") and
      String.contains?(query, ~s("oban_jobs")) and
      String.contains?(query, ~s("state")) and
      String.contains?(query, "ORDER BY") and
      String.contains?(query, "LIMIT $")
  end

  defp target_incomplete_job_count(mailbox_id) do
    mailbox_id
    |> account_job_query()
    |> where([job, _message], job.state in ~w(available scheduled executing retryable suspended))
    |> Repo.aggregate(:count)
  end

  defp target_cancelled_job_count(mailbox_id) do
    mailbox_id
    |> account_job_query()
    |> where([job, _message], job.state == "cancelled")
    |> Repo.aggregate(:count)
  end

  defp account_job_query(mailbox_id) do
    Oban.Job
    |> join(:inner, [job], message in OutboundMessage,
      on: fragment("?->>'outbound_message_id' = ?::text", job.args, message.id)
    )
    |> where(
      [job, message],
      job.worker == ^inspect(SubmitOutbound) and message.mailbox_id == ^mailbox_id
    )
  end

  defp insert_provider_event(outbound_message_id) do
    now = DateTime.utc_now()

    %ProviderEvent{}
    |> ProviderEvent.changeset(%{
      outbound_message_id: outbound_message_id,
      provider: "resend",
      provider_event_id: "purge-#{outbound_message_id}",
      provider_message_id: "provider-#{outbound_message_id}",
      event_type: "delivered",
      normalized_state: "delivered",
      occurred_at: now,
      received_at: now,
      processing_state: "processed",
      processed_at: now
    })
    |> Repo.insert!()
  end

  defp capture_repo_queries(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    event = Keyword.fetch!(Repo.config(), :telemetry_prefix) ++ [:query]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, pid -> send(pid, {:repo_query, metadata.query}) end,
        self()
      )

    try do
      result = fun.()
      {result, collect_repo_queries([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_repo_queries(queries) do
    receive do
      {:repo_query, query} -> collect_repo_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp collect_repo_metadata(metadata) do
    receive do
      {:repo_metadata, entry} -> collect_repo_metadata([entry | metadata])
    after
      0 -> Enum.reverse(metadata)
    end
  end

  defp send_method_fixture(account_id, address, kind) do
    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: account_id,
      kind: kind,
      email_address: address,
      status: "connected",
      enabled: true
    })
    |> Repo.insert!()
  end

  defp expected_raw(message, provider, idempotency_key) do
    recipients = Outbound.list_recipients(message.id)

    envelope = %Envelope{
      from: mailbox(message.sender_name, message.sender_address),
      to: recipient_mailboxes(recipients, "to"),
      cc: recipient_mailboxes(recipients, "cc"),
      bcc: recipient_mailboxes(recipients, "bcc"),
      subject: message.subject,
      text: message.text_body || "",
      message_id: "<#{message.id}@manifold.local>",
      queued_at: message.queued_at,
      in_reply_to: message.in_reply_to,
      references: message.references,
      idempotency_key: idempotency_key
    }

    RfcMessage.render!(envelope,
      provider: String.to_existing_atom(provider),
      message_id: envelope.message_id,
      date: envelope.queued_at
    )
  end

  defp recipient_mailboxes(recipients, kind) do
    recipients
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(&mailbox(&1.display_name, &1.address))
  end

  defp mailbox(nil, address), do: address
  defp mailbox("", address), do: address
  defp mailbox(display_name, address), do: "#{display_name} <#{address}>"

  defp sha256(bytes) do
    bytes
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp assert_secret_free_telemetry(measurements, metadata, secret_values) do
    assert Map.keys(measurements) |> Enum.sort() == [:attempt_count, :duration_ms]

    forbidden_fragments =
      ~w(token password authorization_code raw_message) ++
        Enum.map(secret_values, &String.downcase/1)

    telemetry_terms(measurements)
    |> Enum.concat(telemetry_terms(metadata))
    |> Enum.each(fn term ->
      downcased = term |> to_string() |> String.downcase()

      refute Enum.any?(forbidden_fragments, &String.contains?(downcased, &1)),
             "unsafe telemetry term: #{inspect(term)}"
    end)
  end

  defp telemetry_terms(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> [key | telemetry_terms(value)] end)
  end

  defp telemetry_terms(list) when is_list(list), do: Enum.flat_map(list, &telemetry_terms/1)

  defp telemetry_terms(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> telemetry_terms()

  defp telemetry_terms(value), do: [value]

  defp jobs_for(message_id) do
    from(job in Oban.Job,
      where: fragment("?->>'outbound_message_id'", job.args) == ^message_id
    )
  end

  defp submissions_for(message_id) do
    from(submission in ProviderSubmission,
      where: submission.outbound_message_id == ^message_id
    )
  end

  defp explicit_request_payload(submission_or_message_id) do
    ProviderSubmission
    |> where(
      [submission],
      submission.id == ^submission_or_message_id or
        submission.outbound_message_id == ^submission_or_message_id
    )
    |> select([submission], submission.request_payload)
    |> Repo.one!()
  end
end

defmodule Manifold.OutboundSendMethodLockTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Schema.SendMethod
  alias Manifold.Outbound
  alias Manifold.Outbound.Schema.ProviderSubmission
  alias Manifold.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    :ok
  end

  test "queueing holds the selected method lock through a concurrent disconnect" do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "outbound-lock#{suffix}.test"})

    {:ok, account} =
      Accounts.create_account(domain, %{local_part: "inbox", name: "Local Inbox"})

    address = "inbox@#{domain.normalized_domain}"
    gmail = insert_send_method!(account.id, address, "gmail")

    {:ok, draft} =
      Outbound.create_draft(account.id, %{
        subject: "Ready",
        text_body: "Body",
        recipients: [%{kind: "to", address: "person@example.net"}]
      })

    test_pid = self()
    telemetry_token = make_ref()
    handler_id = "outbound-send-method-lock-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :repo, :query],
        &block_selected_method_query/4,
        %{parent: test_pid, token: telemetry_token}
      )

    queue =
      Task.async(fn ->
        unboxed(fn ->
          Process.put(:outbound_send_method_lock_test, telemetry_token)
          Outbound.queue_draft(account.id, draft.id)
        end)
      end)

    try do
      assert_receive {:send_method_row_locked, queue_pid, ^telemetry_token}

      disconnect =
        Task.async(fn ->
          unboxed(fn ->
            [[backend_pid]] = SQL.query!(Repo, "SELECT pg_backend_pid()", []).rows
            send(test_pid, {:disconnect_backend, backend_pid})
            result = Connectors.disconnect_send_method(account.id, gmail.id)
            send(test_pid, {:send_method_disconnected, result})
            result
          end)
        end)

      Process.put(:outbound_disconnect_task, disconnect)

      assert_receive {:disconnect_backend, backend_pid}
      assert is_binary(wait_for_backend_lock(backend_pid))

      send(queue_pid, {:release_send_method_query, telemetry_token})

      assert {:ok, queued} = Task.await(queue, 5_000)
      assert {:ok, disconnected} = Task.await(disconnect, 5_000)
      assert_receive {:send_method_disconnected, {:ok, ^disconnected}}
      assert disconnected.id == gmail.id
      assert disconnected.status == "disconnected"
      refute disconnected.enabled

      submission = Repo.get_by!(ProviderSubmission, outbound_message_id: queued.id)
      assert submission.send_method_id == gmail.id
      assert submission.provider == "gmail"

      assert {:error, %{reason: :send_method_required}} =
               Connectors.enabled_send_method(account.id)

      assert {:error, %{reason: :account_disconnected}} =
               Connectors.checkout_send_method(gmail.id, address)

      persisted = Repo.get!(ProviderSubmission, submission.id)
      assert persisted.send_method_id == gmail.id
      assert persisted.request_sha256 == submission.request_sha256
    after
      stop_task(Process.delete(:outbound_disconnect_task))
      release_and_stop_task(queue, telemetry_token)
      :telemetry.detach(handler_id)
      cleanup!(account, domain, draft.id)
    end
  end

  defp block_selected_method_query(_event, _measurements, metadata, config) do
    if Process.get(:outbound_send_method_lock_test) == config.token and
         String.contains?(metadata.query, ~s(FROM "connector_send_methods")) and
         String.contains?(metadata.query, "FOR UPDATE") do
      send(config.parent, {:send_method_row_locked, self(), config.token})

      receive do
        {:release_send_method_query, token} when token == config.token -> :ok
      end
    end
  end

  defp wait_for_backend_lock(backend_pid, attempts \\ 200)

  defp wait_for_backend_lock(backend_pid, attempts) when attempts > 0 do
    case SQL.query!(
           Repo,
           "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = $1",
           [backend_pid]
         ).rows do
      [["Lock", wait_event]] when is_binary(wait_event) ->
        wait_event

      _not_waiting ->
        Process.sleep(10)
        wait_for_backend_lock(backend_pid, attempts - 1)
    end
  end

  defp wait_for_backend_lock(backend_pid, 0) do
    flunk("PostgreSQL backend #{backend_pid} never waited on the send-method row lock")
  end

  defp release_and_stop_task(%Task{pid: pid} = task, telemetry_token) do
    send(pid, {:release_send_method_query, telemetry_token})
    stop_task(task)
  end

  defp stop_task(nil), do: :ok

  defp stop_task(%Task{pid: pid} = task) do
    if Process.alive?(pid), do: Task.shutdown(task, :brutal_kill), else: :ok
  end

  defp insert_send_method!(account_id, address, kind) do
    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: account_id,
      kind: kind,
      email_address: address,
      status: "connected",
      enabled: true
    })
    |> Repo.insert!()
  end

  defp cleanup!(account, domain, message_id) do
    Oban.Job
    |> where(
      [job],
      fragment("?->>'outbound_message_id'", job.args) == ^message_id
    )
    |> Repo.delete_all()

    account |> Repo.reload!() |> Repo.delete!()
    domain |> Repo.reload!() |> Repo.delete!()
  end

  defp unboxed(fun), do: Sandbox.unboxed_run(Repo, fun)
end

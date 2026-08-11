defmodule Manifold.OutboundTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Outbound
  alias Manifold.Outbound.Jobs.SubmitOutbound

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
    %{mailbox: mailbox} = mailbox_fixture()
    draft = draft_fixture(mailbox.id)

    assert {:ok, queued} =
             Outbound.queue_draft(mailbox.id, draft.id, expected_revision: draft.lock_version)

    assert queued.state == "queued"
    assert %DateTime{} = queued.queued_at

    assert %Oban.Job{
             worker: worker,
             args: %{"outbound_message_id" => outbound_message_id}
           } =
             Repo.get_by!(Oban.Job,
               worker: inspect(SubmitOutbound),
               args: %{"outbound_message_id" => draft.id}
             )

    assert worker == inspect(SubmitOutbound)
    assert outbound_message_id == draft.id

    assert %ProviderSubmission{
             outbound_message_id: ^outbound_message_id,
             provider: "resend",
             state: "pending",
             idempotency_key: idempotency_key,
             request_sha256: request_sha256,
             idempotency_expires_at: %DateTime{}
           } = Repo.get_by!(ProviderSubmission, outbound_message_id: draft.id)

    assert byte_size(idempotency_key) > 0
    assert byte_size(request_sha256) == 64
    assert Repo.get_by!(OutboundEvent, outbound_message_id: draft.id, event_type: "queued")

    assert {:ok, repeated} = Outbound.queue_draft(mailbox.id, draft.id)
    assert repeated.id == draft.id

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == ^inspect(SubmitOutbound) and
                   fragment("?->>'outbound_message_id'", job.args) == ^draft.id
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(submission in ProviderSubmission,
               where: submission.outbound_message_id == ^draft.id
             ),
             :count
           ) == 1

    assert {:error, %{reason: :message_not_editable}} =
             Outbound.update_draft(mailbox.id, draft.id, %{subject: "Too late"})
  end

  test "queue transaction failure rolls back state and job insertion" do
    %{mailbox: mailbox} = mailbox_fixture()
    draft = draft_fixture(mailbox.id)

    assert {:error, %{reason: :after_queue_before_job}} =
             Outbound.queue_draft(mailbox.id, draft.id, fail_at: :after_queue_before_job)

    assert Repo.get!(OutboundMessage, draft.id).state == "draft"

    refute Repo.get_by(Oban.Job,
             worker: inspect(SubmitOutbound),
             args: %{"outbound_message_id" => draft.id}
           )

    refute Repo.get_by(ProviderSubmission, outbound_message_id: draft.id)
  end

  test "queueing rechecks and locks the active sender before the draft" do
    %{mailbox: mailbox} = mailbox_fixture()
    draft = draft_fixture(mailbox.id)

    {result, queries} =
      capture_repo_queries(fn ->
        Outbound.queue_draft(mailbox.id, draft.id, expected_revision: draft.lock_version)
      end)

    assert {:ok, %OutboundMessage{state: "queued"}} = result

    lock_queries = Enum.filter(queries, &String.contains?(&1, "FOR UPDATE"))
    assert [sender_lock, draft_lock] = lock_queries
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

    %{mailbox: mailbox} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()

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

    %{mailbox: mailbox} = mailbox_fixture()

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
      cleanup_race_fixture(race_repo, job.id, mailbox.id, domain.id)
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

    cleanup_race_fixture(race_repo, job.id, mailbox.id, domain.id)
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
    %{mailbox: mailbox} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()

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
    %{mailbox: mailbox} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()
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
    %{mailbox: mailbox} = mailbox_fixture()
    %{mailbox: other_mailbox} = mailbox_fixture()
    draft = draft_fixture(mailbox.id)
    assert {:ok, queued} = Outbound.queue_draft(mailbox.id, draft.id)

    assert {:ok, detail} = Outbound.get_sent(mailbox.id, queued.id)
    assert detail.id == queued.id
    assert detail.state == "queued"
    assert detail.subject == "Ready"
    assert [%{kind: "to", delivery_state: "pending"}] = detail.recipients
    assert detail.submission.provider == "resend"
    assert detail.submission.state == "pending"
    assert Enum.map(detail.events, & &1.event_type) == ["draft_created", "queued"]

    assert {:error, %{reason: :sent_not_found}} =
             Outbound.get_sent(other_mailbox.id, queued.id)

    assert {:error, %{reason: :sent_not_found}} =
             Outbound.get_sent(mailbox.id, draft_fixture(mailbox.id).id)
  end

  defp draft_fixture(mailbox_id) do
    {:ok, draft} =
      Outbound.create_draft(mailbox_id, %{
        subject: "Ready",
        text_body: "Body",
        recipients: [%{kind: "to", address: "person@example.net"}]
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

  defp cleanup_race_fixture(repo, job_id, mailbox_id, domain_id) do
    if Process.alive?(repo) do
      try do
        on_repo(repo, fn ->
          Oban.Job
          |> where([candidate], candidate.id == ^job_id)
          |> Repo.delete_all()

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
end

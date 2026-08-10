defmodule Manifold.AccountLifecycle.PurgeTest do
  use Manifold.DataCase, async: false
  use Oban.Testing, repo: Manifold.Repo

  import Ecto.Query

  alias Manifold.AccountLifecycle
  alias Manifold.AccountLifecycle.Jobs.PurgeAccount
  alias Manifold.AccountLifecycle.Schema.{AccountPurge, PurgeDelivery, PurgeObject}
  alias Manifold.Accounts
  alias Manifold.Accounts.Schema.Account
  alias Manifold.Connectors.ActivityLog
  alias Manifold.Connectors.Schema.{ReceiveMethod, RemoteMessage, SendMethod}
  alias Manifold.Ingest.Schema.{DeliveryRecipient, InboundDelivery}
  alias Manifold.Ingest.Jobs.ArchiveRawEmail
  alias Manifold.Mail.Schema.{Attachment, MailboxEntry, Message}
  alias Manifold.Outbound
  alias Manifold.Outbound.Schema.OutboundMessage
  alias Manifold.Repo
  alias Manifold.Storage.{BlobStore, RawStore}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    old_storage =
      Map.new([:raw_store_dir, :blob_store_dir, :spool_dir], fn key ->
        {key, Application.fetch_env!(:manifold_storage, key)}
      end)

    old_activity_log_dir = Application.get_env(:manifold_connectors, :activity_log_dir)

    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))
    Application.put_env(:manifold_storage, :blob_store_dir, Path.join(tmp_dir, "blob"))
    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_connectors, :activity_log_dir, Path.join(tmp_dir, "logs"))

    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})

    on_exit(fn ->
      Enum.each(old_storage, fn {key, value} ->
        Application.put_env(:manifold_storage, key, value)
      end)

      if old_activity_log_dir do
        Application.put_env(:manifold_connectors, :activity_log_dir, old_activity_log_dir)
      else
        Application.delete_env(:manifold_connectors, :activity_log_dir)
      end
    end)

    :ok
  end

  test "purges only the target account while retaining a shared delivery and blob", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "purge-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})
    {:ok, other} = Accounts.create_account(domain, %{local_part: "other"})

    shared_blob = put_blob!(tmp_dir, "shared attachment")
    target_blob = put_blob!(tmp_dir, "target attachment")

    shared = delivery_fixture(domain.id, [target.id, other.id], shared_blob, "shared", tmp_dir)
    target_only = delivery_fixture(domain.id, [target.id], target_blob, "target", tmp_dir)

    receive_method = receive_method_fixture(target.id)
    send_method = send_method_fixture(target.id)
    remote = remote_message_fixture(receive_method.id, target_only.delivery.id)
    :ok = ActivityLog.append(receive_method.id, %{event: "purge-test"})

    {:ok, draft} =
      Outbound.create_draft(target.id, %{
        subject: "Private subject",
        text_body: "private body",
        recipients: [%{kind: "to", address: "recipient@example.net"}]
      })

    assert {:ok, queued} = Outbound.queue_draft(target.id, draft.id)

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(target.id, "target@#{domain.normalized_domain}")

    assert %AccountPurge{status: "completed"} = run_until_complete(purge.id)
    completed = Repo.get!(AccountPurge, purge.id)

    refute Repo.get(Account, target.id)
    assert Repo.get!(Account, other.id)
    assert Repo.get!(InboundDelivery, shared.delivery.id)
    assert Repo.get!(Message, shared.message.id)
    assert Repo.get!(Attachment, shared.attachment.id)
    assert Repo.get!(MailboxEntry, shared.entries[other.id].id)
    assert {:ok, _stat} = BlobStore.stat(shared_blob)

    refute Repo.get(InboundDelivery, target_only.delivery.id)
    refute Repo.get(Message, target_only.message.id)
    refute Repo.get(Attachment, target_only.attachment.id)
    assert {:error, _reason} = RawStore.stat(target_only.delivery.raw_object_key)
    assert {:error, _reason} = BlobStore.stat(target_blob)
    refute File.exists?(target_only.delivery.spool_bundle_path)

    refute Repo.get(ReceiveMethod, receive_method.id)
    refute Repo.get(SendMethod, send_method.id)
    refute Repo.get(RemoteMessage, remote.id)
    refute Repo.get(OutboundMessage, queued.id)
    assert {:ok, []} = ActivityLog.list_dates(receive_method.id)

    assert completed.stage == "completed"
    assert completed.progress == %{}
    assert is_nil(completed.error_class)
    assert is_nil(completed.error_code)
    assert is_nil(completed.error_message)
    assert completed.discovered_deliveries == 2
    assert completed.purged_deliveries == 1
    assert completed.shared_retained_deliveries == 1
    assert %DateTime{} = completed.completed_at
    assert Repo.aggregate(PurgeDelivery, :count) == 0
    assert Repo.aggregate(PurgeObject, :count) == 0

    audit = Map.from_struct(completed)

    refute Enum.any?(Map.keys(audit), fn key ->
             key in [:address, :display_name, :credential, :content, :object_key]
           end)
  end

  test "discovery bounds each execution to 250 candidates and resumes exactly", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "bounded-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})

    rows =
      for index <- 1..251 do
        fixture = delivery_fixture(domain.id, [target.id], nil, "batch-#{index}", tmp_dir)
        fixture.delivery.id
      end

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(target.id, "target@#{domain.normalized_domain}")

    counts =
      Enum.reduce_while(1..20, [0], fn _execution, [previous | _] = counts ->
        assert {:snooze, seconds} = perform(purge.id)
        assert seconds in [1, 5]
        current = Repo.aggregate(PurgeDelivery, :count)
        assert current - previous <= 250

        if current == 251 do
          {:halt, [current | counts]}
        else
          {:cont, [current | counts]}
        end
      end)

    assert hd(counts) == 251
    assert length(Enum.uniq(counts)) > 2

    assert Enum.sort(Enum.map(Repo.all(PurgeDelivery), & &1.inbound_delivery_id)) ==
             Enum.sort(rows)

    completed = run_until_complete(purge.id)
    assert completed.discovered_deliveries == 251
    assert completed.purged_deliveries == 251
    assert completed.shared_retained_deliveries == 0
    assert completed.deleted_objects == 502
  end

  test "an executing connector job snoozes before destructive stages" do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "drain-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})
    method = receive_method_fixture(target.id)

    purge =
      %AccountPurge{}
      |> AccountPurge.changeset(%{
        mailbox_id: target.id,
        status: "running",
        stage: "drain",
        progress: %{"source" => "connectors", "complete_sources" => []}
      })
      |> Repo.insert!()

    {:ok, job} =
      %Oban.Job{
        queue: "connectors",
        worker: "Manifold.Connectors.Jobs.SyncAccount",
        args: %{"external_account_id" => method.id},
        state: "executing",
        attempt: 1,
        max_attempts: 20,
        scheduled_at: DateTime.utc_now(),
        attempted_at: DateTime.utc_now()
      }
      |> Repo.insert()

    assert {:snooze, 5} = perform(purge.id)
    assert Repo.get!(ReceiveMethod, method.id)
    assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    assert Repo.get!(AccountPurge, purge.id).stage == "drain"
  end

  test "drain cancels an executing outbound job before advancing" do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "outbound-drain-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})

    {:ok, draft} =
      Outbound.create_draft(target.id, %{
        subject: "Drain me",
        recipients: [%{kind: "to", address: "recipient@example.test"}]
      })

    assert {:ok, queued} = Outbound.queue_draft(target.id, draft.id)

    job =
      Repo.get_by!(Oban.Job,
        worker: "Manifold.Outbound.Jobs.SubmitOutbound",
        args: %{"outbound_message_id" => queued.id}
      )

    job
    |> Ecto.Changeset.change(state: "executing", attempted_at: DateTime.utc_now())
    |> Repo.update!()

    progress = %{"source" => "outbound", "complete_sources" => ["connectors"]}

    purge =
      %AccountPurge{}
      |> AccountPurge.changeset(%{
        mailbox_id: target.id,
        status: "running",
        stage: "drain",
        progress: progress
      })
      |> Repo.insert!()

    assert {:snooze, 5} = perform(purge.id)
    assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    assert Repo.get!(AccountPurge, purge.id).progress == progress

    assert {:snooze, 1} = perform(purge.id)

    assert Repo.get!(AccountPurge, purge.id).progress["complete_sources"] == [
             "connectors",
             "outbound"
           ]
  end

  test "ingest drain holds its delivery cursor until more than 250 current jobs are empty", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "ingest-drain-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})
    fixture = delivery_fixture(domain.id, [target.id], nil, "ingest-drain", tmp_dir)

    progress = %{"source" => "ingest", "complete_sources" => ["connectors", "outbound"]}

    purge =
      %AccountPurge{}
      |> AccountPurge.changeset(%{
        mailbox_id: target.id,
        status: "running",
        stage: "drain",
        progress: progress
      })
      |> Repo.insert!()

    Repo.insert!(%PurgeDelivery{
      purge_id: purge.id,
      inbound_delivery_id: fixture.delivery.id
    })

    now = DateTime.utc_now()

    jobs =
      for index <- 1..251 do
        Repo.insert!(%Oban.Job{
          queue: "archive",
          worker: inspect(ArchiveRawEmail),
          args: %{"inbound_delivery_id" => fixture.delivery.id},
          state: if(index == 1, do: "executing", else: "available"),
          attempt: 1,
          max_attempts: 20,
          scheduled_at: now,
          attempted_at: if(index == 1, do: now)
        })
      end

    assert {:snooze, 5} = perform(purge.id)
    assert Repo.get!(AccountPurge, purge.id).progress == progress
    assert Enum.count(jobs, &(Repo.get!(Oban.Job, &1.id).state == "cancelled")) == 250

    assert {:snooze, 5} = perform(purge.id)
    assert Repo.get!(AccountPurge, purge.id).progress == progress
    assert Enum.all?(jobs, &(Repo.get!(Oban.Job, &1.id).state == "cancelled"))

    assert {:snooze, 1} = perform(purge.id)
    drained = Repo.get!(AccountPurge, purge.id)
    assert drained.stage == "connectors"
    assert drained.progress == %{}
  end

  test "connector cleanup and activity-log outbox roll back together" do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "connector-rollback-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})
    method = receive_method_fixture(target.id)

    purge =
      %AccountPurge{}
      |> AccountPurge.changeset(%{
        mailbox_id: target.id,
        status: "running",
        stage: "connectors"
      })
      |> Repo.insert!()

    assert {:error, :injected_after_connector_delete_before_object_outbox} =
             perform(purge.id,
               meta: %{"fail_at" => "after_connector_delete_before_object_outbox"}
             )

    assert Repo.get!(ReceiveMethod, method.id)
    assert Repo.aggregate(PurgeObject, :count) == 0
    assert Repo.get!(AccountPurge, purge.id).stage == "connectors"
  end

  test "a crash after delivery deletion resumes from durable object work", %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "resume-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})
    blob_key = put_blob!(tmp_dir, "resume attachment")
    fixture = delivery_fixture(domain.id, [target.id], blob_key, "resume", tmp_dir)

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(target.id, "target@#{domain.normalized_domain}")

    assert %AccountPurge{stage: "orphan_payloads"} =
             run_until_stage(purge.id, "orphan_payloads")

    assert {:error, :injected_after_orphan_payload_commit} =
             perform(purge.id,
               meta: %{"fail_at" => "after_orphan_payload_commit"},
               attempt: 1,
               max_attempts: 20
             )

    refute Repo.get(InboundDelivery, fixture.delivery.id)

    assert Repo.get_by!(PurgeDelivery, inbound_delivery_id: fixture.delivery.id).disposition ==
             "purged"

    assert Repo.aggregate(
             from(work in PurgeObject,
               where: work.purge_id == ^purge.id and work.status == "pending"
             ),
             :count
           ) == 3

    assert %AccountPurge{status: "completed"} = run_until_complete(purge.id)
    assert {:error, _reason} = RawStore.stat(fixture.delivery.raw_object_key)
    assert {:error, _reason} = BlobStore.stat(blob_key)
    refute File.exists?(fixture.delivery.spool_bundle_path)
  end

  test "attachment pagination commits a bounded cursor and resumes without duplicate delivery work",
       %{
         tmp_dir: tmp_dir
       } do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "attachment-page-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})
    fixture = delivery_fixture(domain.id, [target.id], nil, "attachment-page", tmp_dir)

    blob_keys =
      for index <- 1..249 do
        sha256 = :crypto.hash(:sha256, "attachment-#{index}") |> Base.encode16(case: :lower)
        {:ok, key} = BlobStore.build_key(sha256)

        %Attachment{}
        |> Attachment.changeset(%{
          message_id: fixture.message.id,
          part_path: Integer.to_string(index),
          media_type: "application/octet-stream",
          disposition: "attachment",
          size: index,
          sha256: sha256,
          object_key: key
        })
        |> Repo.insert!()

        key
      end

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(target.id, "target@#{domain.normalized_domain}")

    assert %AccountPurge{stage: "orphan_payloads"} =
             run_until_stage(purge.id, "orphan_payloads")

    assert {:error, :injected_after_orphan_payload_commit} =
             perform(purge.id,
               meta: %{"fail_at" => "after_orphan_payload_commit"},
               attempt: 1,
               max_attempts: 20
             )

    paged = Repo.get!(AccountPurge, purge.id)
    assert paged.progress["delivery_cursor"] == fixture.delivery.id
    assert is_binary(paged.progress["attachment_cursor"])
    assert Repo.get!(InboundDelivery, fixture.delivery.id)

    assert Repo.aggregate(
             from(work in PurgeObject,
               where:
                 work.purge_id == ^purge.id and work.kind == "blob" and
                   work.status == "pending"
             ),
             :count
           ) == 248

    assert {:snooze, 1} = perform(purge.id)
    refute Repo.get(InboundDelivery, fixture.delivery.id)

    assert Repo.get_by!(PurgeDelivery, inbound_delivery_id: fixture.delivery.id).disposition ==
             "purged"

    assert Repo.get!(AccountPurge, purge.id).purged_deliveries == 1

    queued_keys =
      PurgeObject
      |> where([work], work.purge_id == ^purge.id and work.kind == "blob")
      |> select([work], work.object_key)
      |> Repo.all()

    assert Enum.sort(queued_keys) == Enum.sort(blob_keys)
    assert length(Enum.uniq(queued_keys)) == 249

    completed = run_until_complete(purge.id)
    assert completed.discovered_deliveries == 1
    assert completed.purged_deliveries == 1
    assert completed.deleted_objects == 251
  end

  test "missing raw blob spool and activity log objects are idempotent", %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "missing-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(target.id, "target@#{domain.normalized_domain}")

    purge =
      purge
      |> AccountPurge.changeset(%{status: "running", stage: "objects"})
      |> Repo.update!()

    now = DateTime.utc_now()
    raw_key = RawStore.build_key(domain.id, now, Ecto.UUID.generate())
    {:ok, blob_key} = BlobStore.build_key(String.duplicate("a", 64))
    spool_path = Path.join([tmp_dir, "spool", "ready", Ecto.UUID.generate()])

    insert_object_work!(purge.id, "raw", raw_key)
    insert_object_work!(purge.id, "blob", blob_key)
    insert_object_work!(purge.id, "spool", spool_path)
    insert_object_work!(purge.id, "activity_log", Ecto.UUID.generate())

    assert {:snooze, 1} = perform(purge.id)

    assert Repo.aggregate(
             from(work in PurgeObject,
               where: work.purge_id == ^purge.id and work.status == "completed"
             ),
             :count
           ) == 4

    assert Repo.get!(AccountPurge, purge.id).deleted_objects == 4
  end

  test "object deletion is bounded to 250 rows per execution" do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "object-bound-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})

    purge =
      %AccountPurge{}
      |> AccountPurge.changeset(%{
        mailbox_id: target.id,
        status: "running",
        stage: "objects"
      })
      |> Repo.insert!()

    for _index <- 1..251 do
      insert_object_work!(purge.id, "activity_log", Ecto.UUID.generate())
    end

    assert {:snooze, 1} = perform(purge.id)
    after_first = Repo.get!(AccountPurge, purge.id)
    assert after_first.deleted_objects == 250

    assert {:snooze, 1} = perform(purge.id)
    after_second = Repo.get!(AccountPurge, purge.id)
    assert after_second.deleted_objects - after_first.deleted_objects == 1
    assert after_second.deleted_objects == 251

    assert Repo.aggregate(
             from(work in PurgeObject,
               where: work.purge_id == ^purge.id and work.status == "pending"
             ),
             :count
           ) == 0
  end

  test "transient object failure preserves work and final attempt stores only a safe summary" do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "failure-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(target.id, "target@#{domain.normalized_domain}")

    progress = %{"cursor" => "object-page-1"}

    purge =
      purge
      |> AccountPurge.changeset(%{status: "running", stage: "objects", progress: progress})
      |> Repo.update!()

    {:ok, blob_key} = BlobStore.build_key(String.duplicate("b", 64))
    work = insert_object_work!(purge.id, "blob", blob_key)
    old_backend = Application.get_env(:manifold_storage, :blob_store_backend)

    Application.put_env(
      :manifold_storage,
      :blob_store_backend,
      Manifold.AccountLifecycle.PurgeTest.FailingBlobStore
    )

    on_exit(fn -> restore_env(:manifold_storage, :blob_store_backend, old_backend) end)

    assert {:error, :local_cleanup_failed} =
             perform(purge.id, attempt: 1, max_attempts: 20)

    retryable = Repo.get!(AccountPurge, purge.id)
    assert retryable.status == "running"
    assert retryable.stage == "objects"
    assert retryable.progress == progress
    assert Repo.get!(PurgeObject, work.id).attempts == 1

    assert {:discard, :local_cleanup_failed} =
             perform(purge.id, attempt: 20, max_attempts: 20)

    failed = Repo.get!(AccountPurge, purge.id)
    assert failed.status == "failed"
    assert failed.stage == "objects"
    assert failed.progress == progress
    assert byte_size(failed.error_message) <= 500

    sensitive = [blob_key, "/private/path", "target@failure.test", "secret content"]
    serialized = Enum.join([failed.error_class, failed.error_code, failed.error_message], " ")
    refute Enum.any?(sensitive, &String.contains?(serialized, &1))

    PurgeAccount
    |> purge_job_query(purge.id)
    |> Repo.update_all(set: [state: "discarded"])

    restore_env(:manifold_storage, :blob_store_backend, old_backend)
    assert {:ok, retried} = AccountLifecycle.retry_deletion(purge.id)
    assert retried.id == purge.id
    assert retried.stage == "objects"
    assert retried.progress == progress
    assert Repo.get!(PurgeObject, work.id).status == "pending"

    assert {:snooze, 1} = perform(purge.id)
    assert Repo.get!(PurgeObject, work.id).status == "completed"
    assert Repo.get!(AccountPurge, purge.id).discovered_deliveries == 0
  end

  test "final verification routes remaining mailbox data back to its owning stage", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "verify-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(target.id, "target@#{domain.normalized_domain}")

    fixture = delivery_fixture(domain.id, [target.id], nil, "late", tmp_dir)

    purge
    |> AccountPurge.changeset(%{
      status: "running",
      stage: "finalize",
      progress: %{"phase" => "verify"}
    })
    |> Repo.update!()

    assert {:snooze, 1} = perform(purge.id)
    assert Repo.get!(AccountPurge, purge.id).stage == "mailbox_copy"
    assert Repo.get!(Account, target.id)
    assert Repo.get!(InboundDelivery, fixture.delivery.id)
  end

  test "finalization rediscovers and redrains a late delivery before completion", %{
    tmp_dir: tmp_dir
  } do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "late-finalize-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(target.id, "target@#{domain.normalized_domain}")

    fixture = delivery_fixture(domain.id, [target.id], nil, "late-finalize", tmp_dir)
    now = DateTime.utc_now()

    job =
      Repo.insert!(%Oban.Job{
        queue: "archive",
        worker: inspect(ArchiveRawEmail),
        args: %{"inbound_delivery_id" => fixture.delivery.id},
        state: "executing",
        attempt: 1,
        max_attempts: 20,
        scheduled_at: now,
        attempted_at: now
      })

    purge
    |> AccountPurge.changeset(%{
      status: "running",
      stage: "finalize",
      progress: %{"phase" => "discover", "complete_sources" => []}
    })
    |> Repo.update!()

    _drain_ready =
      Enum.reduce_while(1..20, nil, fn _execution, _last ->
        current = Repo.get!(AccountPurge, purge.id)

        if current.progress["phase"] == "drain" and
             current.progress["complete_sources"] == ["connectors", "outbound"] do
          {:halt, current}
        else
          assert {:snooze, 1} = perform(purge.id)
          refute Repo.get!(AccountPurge, purge.id).status == "completed"
          {:cont, current}
        end
      end) || flunk("finalization did not reach ingest redrain")

    assert Repo.get_by!(PurgeDelivery, inbound_delivery_id: fixture.delivery.id)
    assert Repo.get!(Account, target.id)

    assert {:snooze, 5} = perform(purge.id)
    assert Repo.get!(Oban.Job, job.id).state == "cancelled"

    assert Repo.get!(AccountPurge, purge.id).progress["complete_sources"] == [
             "connectors",
             "outbound"
           ]

    completed = run_until_complete(purge.id)
    assert completed.discovered_deliveries == 1
    assert completed.purged_deliveries == 1
    refute Repo.get(Account, target.id)
    refute Repo.get(InboundDelivery, fixture.delivery.id)
  end

  test "final account FK failure rolls back to a savepoint and routes by constraint owner" do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "fk-route-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(target.id, "target@#{domain.normalized_domain}")

    Repo.query!("""
    CREATE TABLE purge_outbound_residuals (
      id uuid PRIMARY KEY,
      mailbox_id uuid NOT NULL,
      CONSTRAINT outbound_residual_mailbox_fkey
        FOREIGN KEY (mailbox_id) REFERENCES mailboxes(id)
    )
    """)

    Repo.query!(
      "INSERT INTO purge_outbound_residuals (id, mailbox_id) VALUES ($1, $2)",
      [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(target.id)]
    )

    try do
      purge
      |> AccountPurge.changeset(%{
        status: "running",
        stage: "finalize",
        progress: %{"phase" => "verify"}
      })
      |> Repo.update!()

      assert {:snooze, 1} = perform(purge.id)

      routed = Repo.get!(AccountPurge, purge.id)
      assert routed.status == "running"
      assert routed.stage == "outbound"
      assert routed.progress == %{}
      assert Repo.get!(Account, target.id)
    after
      Repo.query!("DROP TABLE IF EXISTS purge_outbound_residuals")
    end
  end

  test "duplicate completed executions preserve counters and terminal state", %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "duplicate-run-#{suffix}.test"})
    {:ok, target} = Accounts.create_account(domain, %{local_part: "target"})
    _fixture = delivery_fixture(domain.id, [target.id], nil, "duplicate", tmp_dir)

    assert {:ok, purge} =
             AccountLifecycle.request_deletion(target.id, "target@#{domain.normalized_domain}")

    completed = run_until_complete(purge.id)
    counters = purge_counters(completed)
    assert :ok = perform(purge.id)
    assert :ok = perform(purge.id)
    assert purge_counters(Repo.get!(AccountPurge, purge.id)) == counters
  end

  defp perform(purge_id, attrs \\ %{}) do
    defaults = %{args: %{"purge_id" => purge_id}, attempt: 1, max_attempts: 20, meta: %{}}
    PurgeAccount.perform(struct!(Oban.Job, Map.merge(defaults, Map.new(attrs))))
  end

  defp run_until_complete(purge_id) do
    Enum.reduce_while(1..800, nil, fn _execution, _last ->
      result = perform(purge_id)
      purge = Repo.get!(AccountPurge, purge_id)

      if purge.status == "completed" do
        assert result == :ok
        assert :ok = perform(purge_id)
        {:halt, purge}
      else
        assert result in [{:snooze, 1}, {:snooze, 5}]
        {:cont, purge}
      end
    end) || flunk("purge did not complete within 800 bounded executions")
  end

  defp run_until_stage(purge_id, stage) do
    Enum.reduce_while(1..100, nil, fn _execution, _last ->
      purge = Repo.get!(AccountPurge, purge_id)

      if purge.stage == stage do
        {:halt, purge}
      else
        assert perform(purge_id) in [{:snooze, 1}, {:snooze, 5}]
        {:cont, purge}
      end
    end) || flunk("purge did not reach #{stage} within 100 bounded executions")
  end

  defp insert_object_work!(purge_id, kind, object_key) do
    Repo.insert!(%PurgeObject{purge_id: purge_id, kind: kind, object_key: object_key})
  end

  defp purge_job_query(worker, purge_id) do
    from(job in Oban.Job,
      where:
        job.worker == ^inspect(worker) and
          fragment("?->>'purge_id'", job.args) == ^purge_id
    )
  end

  defp purge_counters(purge) do
    Map.take(purge, [
      :discovered_deliveries,
      :purged_deliveries,
      :shared_retained_deliveries,
      :deleted_objects,
      :status,
      :stage,
      :completed_at
    ])
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp delivery_fixture(domain_id, mailbox_ids, blob_key, suffix, tmp_dir) do
    now = DateTime.utc_now()
    delivery_id = Ecto.UUID.generate()
    raw = "raw #{suffix}"
    raw_key = RawStore.build_key(domain_id, now, delivery_id)
    source = Path.join(tmp_dir, "#{delivery_id}.eml")
    File.write!(source, raw)
    assert {:ok, _stat} = RawStore.put_from_path(raw_key, source)

    spool_path = Path.join([tmp_dir, "spool", "ready", delivery_id])
    File.mkdir_p!(spool_path)
    File.write!(Path.join(spool_path, "raw.eml"), raw)

    delivery =
      Repo.insert!(%InboundDelivery{
        ingest_id: Ecto.UUID.generate(),
        source_kind: "provider_import",
        storage_domain_id: domain_id,
        received_at: now,
        raw_size: byte_size(raw),
        raw_sha256: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower),
        raw_object_key: raw_key,
        spool_bundle_path: spool_path,
        raw_storage_state: "archived",
        processing_state: "processed"
      })

    message =
      %Message{}
      |> Message.changeset(%{
        inbound_delivery_id: delivery.id,
        subject: "subject #{suffix}",
        text_body: "content #{suffix}",
        parser_version: 1,
        sanitizer_version: 1,
        parse_state: "parsed"
      })
      |> Repo.insert!()

    attachment =
      if blob_key do
        %Attachment{}
        |> Attachment.changeset(%{
          message_id: message.id,
          part_path: "1",
          media_type: "application/octet-stream",
          disposition: "attachment",
          size: byte_size(suffix <> " attachment"),
          sha256: Path.basename(blob_key),
          object_key: blob_key
        })
        |> Repo.insert!()
      end

    entries =
      Map.new(mailbox_ids, fn mailbox_id ->
        recipient = "#{suffix}@example.test"

        Repo.insert!(%DeliveryRecipient{
          inbound_delivery_id: delivery.id,
          mailbox_id: mailbox_id,
          original_address: recipient,
          canonical_address: recipient
        })

        entry =
          %MailboxEntry{}
          |> MailboxEntry.changeset(%{
            mailbox_id: mailbox_id,
            inbound_delivery_id: delivery.id,
            message_id: message.id,
            original_recipient: recipient,
            quarantined: false
          })
          |> Repo.insert!()

        {mailbox_id, entry}
      end)

    %{delivery: delivery, message: message, attachment: attachment, entries: entries}
  end

  defp put_blob!(tmp_dir, content) do
    sha256 = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    {:ok, key} = BlobStore.build_key(sha256)
    source = Path.join(tmp_dir, sha256)
    File.write!(source, content)

    assert {:ok, _stat} =
             BlobStore.put_from_path(key, source, expected_size: byte_size(content))

    key
  end

  defp receive_method_fixture(mailbox_id) do
    %ReceiveMethod{}
    |> ReceiveMethod.changeset(%{
      account_id: mailbox_id,
      kind: "gmail",
      provider_account_id: Ecto.UUID.generate(),
      email_address: "target@example.test",
      status: "connected",
      enabled: false,
      sync_enabled: false,
      granted_scopes: []
    })
    |> Repo.insert!()
  end

  defp send_method_fixture(mailbox_id) do
    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: mailbox_id,
      kind: "smtp",
      email_address: "target@example.test",
      status: "connected",
      enabled: false
    })
    |> Repo.insert!()
  end

  defp remote_message_fixture(method_id, delivery_id) do
    %RemoteMessage{}
    |> RemoteMessage.changeset(%{
      external_account_id: method_id,
      provider_message_id: Ecto.UUID.generate(),
      inbound_delivery_id: delivery_id,
      remote_labels: [],
      remote_read: false,
      remote_starred: false,
      remote_deleted: false,
      state: "imported"
    })
    |> Repo.insert!()
  end
end

defmodule Manifold.AccountLifecycle.PurgeTest.FailingBlobStore do
  @behaviour Manifold.Storage.BlobStore

  @impl true
  def put_from_path(_config, _key, _source_path, _opts), do: {:error, :unsupported}

  @impl true
  def open(_config, _key, _opts), do: {:error, :unsupported}

  @impl true
  def stat(_config, _key, _opts), do: {:error, :unsupported}

  @impl true
  def delete(_config, key, _opts) do
    {:error, {:temporary_storage_failure, key, "/private/path", "secret content"}}
  end
end

defmodule Manifold.AccountLifecycle.PurgeBlobPublicationConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Manifold.AccountLifecycle.Jobs.PurgeAccount
  alias Manifold.AccountLifecycle.Schema.{AccountPurge, PurgeObject}
  alias Manifold.Mail
  alias Manifold.Mail.InboundSource
  alias Manifold.Mail.Schema.{Attachment, MailboxEntry}
  alias Manifold.Repo
  alias Manifold.Storage.{BlobStore, RawStore}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)
    old_blob = Application.fetch_env!(:manifold_storage, :blob_store_dir)
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))
    Application.put_env(:manifold_storage, :blob_store_dir, Path.join(tmp_dir, "blobs"))

    fixture = publication_fixture(tmp_dir)

    on_exit(fn ->
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
      Application.put_env(:manifold_storage, :blob_store_dir, old_blob)
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        Repo.query!("DELETE FROM account_purge_objects WHERE purge_id = $1::uuid", [
          Ecto.UUID.dump!(fixture.purge_id)
        ])

        Repo.query!("DELETE FROM account_purges WHERE id = $1::uuid", [
          Ecto.UUID.dump!(fixture.purge_id)
        ])

        Repo.query!("DELETE FROM inbound_deliveries WHERE id = $1::uuid", [
          Ecto.UUID.dump!(fixture.delivery_id)
        ])

        Repo.query!("DELETE FROM mailboxes WHERE id = $1::uuid", [
          Ecto.UUID.dump!(fixture.mailbox_id)
        ])

        Repo.query!("DELETE FROM domains WHERE id = $1::uuid", [
          Ecto.UUID.dump!(fixture.domain_id)
        ])
      after
        Sandbox.checkin(Repo)
      end
    end)

    {:ok, fixture: fixture}
  end

  test "purge object cleanup waits for publication and retains the committed blob", %{
    fixture: fixture
  } do
    test_pid = self()
    barrier_ref = make_ref()

    publisher =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          Mail.project_inbound(fixture.source,
            after_blob_storage_before_commit: fn ->
              send(test_pid, {:blob_stored, self(), barrier_ref})

              receive do
                {:commit_projection, ^barrier_ref} -> :ok
              after
                5_000 -> raise "timed out waiting to commit blob publication"
              end
            end
          )
        after
          Sandbox.checkin(Repo)
        end
      end)

    publisher_pid = publisher.pid
    assert_receive {:blob_stored, ^publisher_pid, ^barrier_ref}, 5_000
    assert {:ok, _stat} = BlobStore.stat(fixture.blob_key)
    refute Mail.blob_referenced?(fixture.blob_key)

    purge =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
          send(test_pid, {:purge_started, self(), backend_pid, barrier_ref})

          PurgeAccount.perform(%Oban.Job{
            args: %{"purge_id" => fixture.purge_id},
            attempt: 1,
            max_attempts: 20,
            meta: %{}
          })
        after
          Sandbox.checkin(Repo)
        end
      end)

    purge_pid = purge.pid
    assert_receive {:purge_started, ^purge_pid, purge_backend_pid, ^barrier_ref}, 5_000
    assert_advisory_wait(purge_backend_pid, 5_000)

    send(publisher_pid, {:commit_projection, barrier_ref})
    assert {:ok, %{state: :parsed}} = Task.await(publisher, 5_000)
    assert {:snooze, 1} = Task.await(purge, 5_000)

    assert Repo.get_by!(Attachment, object_key: fixture.blob_key)
    assert Repo.get!(PurgeObject, fixture.object_id).status == "completed"
    assert Repo.get!(AccountPurge, fixture.purge_id).deleted_objects == 0
    assert {:ok, _stat} = BlobStore.stat(fixture.blob_key)
  end

  defp assert_advisory_wait(backend_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      Repo.query!(
        "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = $1",
        [backend_pid]
      ).rows
    end)
    |> Enum.reduce_while(nil, fn
      [["Lock", "advisory"]], _state ->
        {:halt, :ok}

      _rows, _state ->
        if System.monotonic_time(:millisecond) < deadline do
          {:cont, nil}
        else
          flunk("purge did not block on the blob advisory lock")
        end
    end)
  end

  defp publication_fixture(tmp_dir) do
    now = DateTime.utc_now()
    domain_id = Ecto.UUID.generate()
    mailbox_id = Ecto.UUID.generate()
    delivery_id = Ecto.UUID.generate()
    purge_id = Ecto.UUID.generate()
    object_id = Ecto.UUID.generate()
    domain = "purge-blob-race-#{domain_id}.test"
    attachment = "serialized purge publication #{delivery_id}"
    digest = :crypto.hash(:sha256, attachment) |> Base.encode16(case: :lower)
    {:ok, blob_key} = BlobStore.build_key(digest)

    raw = multipart_message(attachment)
    raw_sha256 = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    raw_key = RawStore.build_key(domain_id, now, delivery_id)
    raw_path = Path.join(tmp_dir, delivery_id <> ".eml")
    File.write!(raw_path, raw)
    {:ok, _stat} = RawStore.put_from_path(raw_key, raw_path)

    Repo.insert_all("domains", [
      %{
        id: Ecto.UUID.dump!(domain_id),
        name: domain,
        normalized_domain: domain,
        active: true,
        plus_addressing_enabled: true,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all("mailboxes", [
      %{
        id: Ecto.UUID.dump!(mailbox_id),
        domain_id: Ecto.UUID.dump!(domain_id),
        local_part: "inbox",
        canonical_local_part: "inbox",
        active: false,
        plus_addressing_enabled: true,
        purge_requested_at: now,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all("inbound_deliveries", [
      %{
        id: Ecto.UUID.dump!(delivery_id),
        ingest_id: Ecto.UUID.generate(),
        source_kind: "provider_import",
        storage_domain_id: Ecto.UUID.dump!(domain_id),
        received_at: now,
        raw_size: byte_size(raw),
        raw_sha256: raw_sha256,
        raw_object_key: raw_key,
        spool_bundle_path: Path.join(tmp_dir, "removed-spool"),
        raw_storage_state: "archived",
        processing_state: "archived",
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert!(
      MailboxEntry.changeset(%MailboxEntry{}, %{
        mailbox_id: mailbox_id,
        inbound_delivery_id: delivery_id,
        original_recipient: "inbox@#{domain}",
        quarantined: false
      })
    )

    Repo.insert_all("account_purges", [
      %{
        id: Ecto.UUID.dump!(purge_id),
        mailbox_id: Ecto.UUID.dump!(mailbox_id),
        status: "running",
        stage: "objects",
        progress: %{},
        discovered_deliveries: 0,
        purged_deliveries: 0,
        shared_retained_deliveries: 0,
        deleted_objects: 0,
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.insert_all("account_purge_objects", [
      %{
        id: Ecto.UUID.dump!(object_id),
        purge_id: Ecto.UUID.dump!(purge_id),
        kind: "blob",
        object_key: blob_key,
        status: "pending",
        attempts: 0,
        inserted_at: now,
        updated_at: now
      }
    ])

    %{
      domain_id: domain_id,
      mailbox_id: mailbox_id,
      delivery_id: delivery_id,
      purge_id: purge_id,
      object_id: object_id,
      blob_key: blob_key,
      source: %InboundSource{
        inbound_delivery_id: delivery_id,
        raw_object_key: raw_key,
        raw_size: byte_size(raw),
        raw_sha256: raw_sha256,
        received_at: now,
        source_kind: "provider_import"
      }
    }
  end

  defp multipart_message(attachment) do
    "From: Sender <sender@example.net>\r\n" <>
      "To: inbox@example.test\r\n" <>
      "Subject: Purge blob race\r\n" <>
      "Message-ID: <purge-blob-race@example.test>\r\n" <>
      "Content-Type: multipart/mixed; boundary=race\r\n\r\n" <>
      "--race\r\nContent-Type: text/plain\r\n\r\nBody\r\n" <>
      "--race\r\nContent-Type: application/octet-stream; name=blob.bin\r\n" <>
      "Content-Disposition: attachment; filename=blob.bin\r\n" <>
      "Content-Transfer-Encoding: base64\r\n\r\n" <>
      Base.encode64(attachment) <>
      "\r\n--race--\r\n"
  end
end

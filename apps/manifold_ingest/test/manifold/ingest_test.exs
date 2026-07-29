defmodule Manifold.IngestTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Ingest
  alias Manifold.Ingest.Jobs.{ArchiveRawEmail, ProjectInboundMail}
  alias Manifold.Ingest.Reconciler
  alias Manifold.Ingest.Schema.{DeliveryRecipient, InboundDelivery, MessageEvent}
  alias Manifold.Mail.Schema.{MailboxEntry, Message}
  alias Manifold.Repo
  alias Manifold.Storage.RawStore
  alias Manifold.Storage.Spool

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    old_spool = Application.fetch_env!(:manifold_storage, :spool_dir)
    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)
    old_blob = Application.fetch_env!(:manifold_storage, :blob_store_dir)

    spool_dir = Path.join(tmp_dir, "spool")
    raw_dir = Path.join(tmp_dir, "raw_store")

    Application.put_env(:manifold_storage, :spool_dir, spool_dir)
    Application.put_env(:manifold_storage, :raw_store_dir, raw_dir)
    Application.put_env(:manifold_storage, :blob_store_dir, Path.join(tmp_dir, "blob_store"))

    on_exit(fn ->
      Application.put_env(:manifold_storage, :spool_dir, old_spool)
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
      Application.put_env(:manifold_storage, :blob_store_dir, old_blob)
    end)

    {:ok, spool_dir: spool_dir, raw_dir: raw_dir}
  end

  test "acceptance creates all rows and inserts archival job transactionally" do
    %{route: route} = route_fixture()

    assert {:ok, delivery} = accept_delivery([route])
    assert Repo.get_by!(InboundDelivery, ingest_id: delivery.ingest_id)
    assert Repo.aggregate(DeliveryRecipient, :count) == 1
    assert Repo.aggregate(MailboxEntry, :count) == 1
    assert Repo.get_by!(MessageEvent, event_type: "accepted")
    assert [%Oban.Job{worker: worker}] = Repo.all(Oban.Job)
    assert worker == inspect(ArchiveRawEmail)
  end

  test "multiple routes preserve all transport recipient records" do
    %{domain: domain, route: first_route} = route_fixture()
    {:ok, second} = Accounts.create_mailbox(domain, %{local_part: "second"})

    second_route = %{
      first_route
      | original_recipient: "second@#{domain.normalized_domain}",
        canonical_recipient: "second@#{domain.normalized_domain}",
        mailbox_ids: [second.id]
    }

    assert {:ok, _delivery} = accept_delivery([first_route, second_route])
    assert Repo.aggregate(DeliveryRecipient, :count) == 2
    assert Repo.aggregate(MailboxEntry, :count) == 2
  end

  test "duplicate routes to one mailbox create one mailbox entry" do
    %{domain: domain, mailbox: mailbox, route: first_route} = route_fixture()

    second_route = %{
      first_route
      | original_recipient: "alias@#{domain.normalized_domain}",
        canonical_recipient: "alias@#{domain.normalized_domain}",
        mailbox_ids: [mailbox.id]
    }

    assert {:ok, _delivery} = accept_delivery([first_route, second_route])
    assert Repo.aggregate(DeliveryRecipient, :count) == 2
    assert Repo.aggregate(MailboxEntry, :count) == 1
  end

  test "acceptance transaction failure does not report success" do
    %{route: route} = route_fixture()

    assert {:ok, bundle} =
             Spool.write_bundle(
               raw_message(),
               Map.put(spool_attrs([route]), :routes, [route]),
               ingest_id: "tx-failure"
             )

    assert {:error, %{reason: :after_delivery_insert_before_commit}} =
             Ingest.accept(bundle, [route], fail_at: :after_delivery_insert_before_commit)

    refute Repo.get_by(InboundDelivery, ingest_id: "tx-failure")
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "acceptance rejects empty frozen routes before writing database state" do
    assert {:ok, bundle} =
             Spool.write_bundle(raw_message(), spool_attrs([]), ingest_id: "empty-routes")

    assert {:error, %{class: :permanent, reason: :invalid_routes}} =
             Ingest.accept(bundle, [])

    refute Repo.get_by(InboundDelivery, ingest_id: "empty-routes")
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "acceptance rejects routes that differ from the durable manifest" do
    %{route: route} = route_fixture()

    assert {:ok, bundle} =
             Spool.write_bundle(raw_message(), spool_attrs([route]), ingest_id: "route-mismatch")

    changed_route = %{route | original_recipient: "other@example.test"}

    assert {:error, %{class: :permanent, reason: :invalid_routes}} =
             Ingest.accept(bundle, [changed_route])

    refute Repo.get_by(InboundDelivery, ingest_id: "route-mismatch")
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "repeated archival job is idempotent" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])

    assert :ok = Ingest.archive_delivery(delivery.id)
    assert :ok = Ingest.archive_delivery(delivery.id)

    delivery = Repo.get!(InboundDelivery, delivery.id)
    assert delivery.raw_storage_state == "archived"

    assert Repo.aggregate(
             from(event in MessageEvent,
               where: event.inbound_delivery_id == ^delivery.id and event.event_type == "archived"
             ),
             :count
           ) == 1

    refute File.exists?(delivery.spool_bundle_path)
  end

  test "archival commits the projection job and projection completes the delivery" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])

    assert :ok = Ingest.archive_delivery(delivery.id)

    assert %Oban.Job{} =
             Repo.get_by(Oban.Job,
               worker: inspect(ProjectInboundMail),
               args: %{
                 "inbound_delivery_id" => delivery.id,
                 "parser_version" => 1,
                 "sanitizer_version" => 1
               }
             )

    assert :ok =
             ProjectInboundMail.perform(%Oban.Job{
               args: %{
                 "inbound_delivery_id" => delivery.id,
                 "parser_version" => 1,
                 "sanitizer_version" => 1
               }
             })

    projected = Repo.get!(InboundDelivery, delivery.id)
    assert projected.processing_state == "processed"
    assert Repo.get_by!(Message, inbound_delivery_id: delivery.id)
    assert Repo.get_by!(MailboxEntry, inbound_delivery_id: delivery.id).message_id
    assert Repo.get_by!(MessageEvent, inbound_delivery_id: delivery.id, event_type: "parsed")
  end

  test "projection worker honors its parser version and rebuilds a completed projection" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])
    assert :ok = Ingest.archive_delivery(delivery.id)
    assert :ok = Ingest.project_delivery(delivery.id, parser_version: 1)

    message = Repo.get_by!(Message, inbound_delivery_id: delivery.id)
    assert message.parser_version == 1

    assert :ok =
             ProjectInboundMail.perform(%Oban.Job{
               args: %{
                 "inbound_delivery_id" => delivery.id,
                 "parser_version" => 2,
                 "sanitizer_version" => 1
               }
             })

    rebuilt = Repo.get_by!(Message, inbound_delivery_id: delivery.id)
    assert rebuilt.id == message.id
    assert rebuilt.parser_version == 2
    assert Repo.get!(InboundDelivery, delivery.id).processing_state == "processed"
  end

  test "projection commit before ingest state update is safe to retry" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])
    assert :ok = Ingest.archive_delivery(delivery.id)

    assert {:error, %{reason: :after_projection_before_state_update}} =
             Ingest.project_delivery(delivery.id, fail_at: :after_projection_before_state_update)

    assert Repo.get!(InboundDelivery, delivery.id).processing_state == "parsing"
    assert Repo.aggregate(Message, :count) == 1

    assert :ok = Ingest.project_delivery(delivery.id)
    assert Repo.get!(InboundDelivery, delivery.id).processing_state == "processed"
    assert Repo.aggregate(Message, :count) == 1

    assert Repo.aggregate(
             from(event in MessageEvent,
               where: event.inbound_delivery_id == ^delivery.id and event.event_type == "parsed"
             ),
             :count
           ) == 1
  end

  test "permanent projection failure is recorded and not recreated by reconciliation", %{
    raw_dir: raw_dir
  } do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])
    assert :ok = Ingest.archive_delivery(delivery.id)

    archived = Repo.get!(InboundDelivery, delivery.id)
    File.write!(Path.join(raw_dir, archived.raw_object_key), "corrupt")

    assert {:cancel, :raw_verification_failed} =
             ProjectInboundMail.perform(%Oban.Job{
               args: %{
                 "inbound_delivery_id" => delivery.id,
                 "parser_version" => 1,
                 "sanitizer_version" => 1
               }
             })

    failed = Repo.get!(InboundDelivery, delivery.id)
    assert failed.processing_state == "failed"
    assert failed.last_error == "archived raw message does not match metadata"

    assert Repo.get_by!(MessageEvent,
             inbound_delivery_id: delivery.id,
             event_type: "projection_failed"
           )

    ProjectInboundMail
    |> inspect()
    |> then(fn worker -> from(job in Oban.Job, where: job.worker == ^worker) end)
    |> Repo.delete_all()

    assert :ok = Reconciler.reconcile_once(root: Spool.spool_root())

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == ^inspect(ProjectInboundMail) and
                   fragment("?->>'inbound_delivery_id' = ?", job.args, ^delivery.id)
             ),
             :count
           ) == 0
  end

  test "reconciliation restores missing projection work for archived deliveries" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])
    assert :ok = Ingest.archive_delivery(delivery.id)

    ProjectInboundMail
    |> inspect()
    |> then(fn worker ->
      from(job in Oban.Job, where: job.worker == ^worker)
    end)
    |> Repo.delete_all()

    assert :ok = Reconciler.reconcile_once(root: Spool.spool_root())

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == ^inspect(ProjectInboundMail) and
                   fragment("?->>'inbound_delivery_id' = ?", job.args, ^delivery.id)
             ),
             :count
           ) == 1
  end

  test "reconciliation schedules the exact upgraded projection beside stale active work" do
    old_parser_version = Application.fetch_env!(:manifold_mail, :parser_version)
    old_sanitizer_version = Application.fetch_env!(:manifold_mail, :sanitizer_version)

    on_exit(fn ->
      Application.put_env(:manifold_mail, :parser_version, old_parser_version)
      Application.put_env(:manifold_mail, :sanitizer_version, old_sanitizer_version)
    end)

    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])
    assert :ok = Ingest.archive_delivery(delivery.id)
    assert :ok = Ingest.project_delivery(delivery.id, parser_version: 1, sanitizer_version: 1)

    Application.put_env(:manifold_mail, :parser_version, 2)
    Application.put_env(:manifold_mail, :sanitizer_version, 2)

    assert :ok = Reconciler.reconcile_once(root: Spool.spool_root())

    jobs =
      ProjectInboundMail
      |> inspect()
      |> then(fn worker ->
        from(job in Oban.Job,
          where:
            job.worker == ^worker and
              fragment("?->>'inbound_delivery_id' = ?", job.args, ^delivery.id),
          order_by: [asc: job.id]
        )
      end)
      |> Repo.all()

    assert [
             %Oban.Job{args: %{"parser_version" => 1, "sanitizer_version" => 1}},
             %Oban.Job{args: %{"parser_version" => 2, "sanitizer_version" => 2}} = upgraded_job
           ] = jobs

    assert :ok = ProjectInboundMail.perform(upgraded_job)

    message = Repo.get_by!(Message, inbound_delivery_id: delivery.id)
    assert message.parser_version == 2
    assert message.sanitizer_version == 2
  end

  test "object-store failure leaves ready bundle and retries" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])

    assert {:error, %{reason: :object_store_failed}} =
             Ingest.archive_delivery(delivery.id, raw_store_opts: [fail_at: :before_copy])

    delivery = Repo.get!(InboundDelivery, delivery.id)
    assert delivery.raw_storage_state == "spooled"
    assert File.exists?(delivery.spool_bundle_path)

    assert :ok = ArchiveRawEmail.perform(%Oban.Job{args: %{"inbound_delivery_id" => delivery.id}})
  end

  test "retry repairs a corrupt raw object before committing archived state" do
    %{domain: domain, route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])

    key = RawStore.build_key(domain.id, delivery.received_at, delivery.id)

    assert {:error, %{reason: :after_raw_copy_before_update}} =
             Ingest.archive_delivery(delivery.id, fail_at: :after_raw_copy_before_update)

    raw_path =
      Application.fetch_env!(:manifold_storage, :raw_store_dir)
      |> Path.join(key)

    File.write!(raw_path, "truncated")

    assert :ok = Ingest.archive_delivery(delivery.id)
    assert {:ok, %{size: size, sha256: sha256}} = RawStore.stat(key)
    assert size == delivery.raw_size
    assert sha256 == delivery.raw_sha256
  end

  test "successful archive records object key before cleanup" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])

    assert {:error, %{reason: :after_archived_state_before_cleanup}} =
             Ingest.archive_delivery(delivery.id, fail_at: :after_archived_state_before_cleanup)

    delivery = Repo.get!(InboundDelivery, delivery.id)
    assert delivery.raw_storage_state == "archived"
    assert is_binary(delivery.raw_object_key)
    assert File.exists?(delivery.spool_bundle_path)

    assert :ok = Ingest.archive_delivery(delivery.id)
    refute File.exists?(delivery.spool_bundle_path)
  end

  test "archived cleanup retains the spool when the raw object cannot be verified" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])

    assert {:error, %{reason: :after_archived_state_before_cleanup}} =
             Ingest.archive_delivery(delivery.id, fail_at: :after_archived_state_before_cleanup)

    delivery = Repo.get!(InboundDelivery, delivery.id)
    assert :ok = RawStore.delete(delivery.raw_object_key)

    assert {:error, %{reason: :object_store_failed}} =
             Ingest.archive_delivery(delivery.id)

    assert File.exists?(delivery.spool_bundle_path)
  end

  test "reconciliation inserts at most one actionable archival job" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])

    assert :ok = Reconciler.reconcile_once(root: Spool.spool_root())
    assert :ok = Reconciler.reconcile_once(root: Spool.spool_root())

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == ^inspect(ArchiveRawEmail) and
                   fragment("?->>'inbound_delivery_id' = ?", job.args, ^delivery.id)
             ),
             :count
           ) == 1
  end

  test "reconciliation removes expired partial bundles" do
    partial = Path.join([Spool.spool_root(), "tmp", "expired.partial"])
    File.mkdir_p!(partial)

    assert :ok =
             Reconciler.reconcile_once(
               root: Spool.spool_root(),
               partial_retention_seconds: 0
             )

    refute File.exists?(partial)
  end

  test "reconciliation restores a previously missing bundle and resumes archival" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])
    assert :ok = Spool.remove_ready_bundle(delivery.spool_bundle_path)

    assert :ok = Reconciler.reconcile_once(root: Spool.spool_root())
    assert Repo.get!(InboundDelivery, delivery.id).raw_storage_state == "missing_spool"

    assert {:ok, _bundle} =
             Spool.write_bundle(
               raw_message(),
               Map.put(spool_attrs([route]), :routes, [route]),
               ingest_id: delivery.ingest_id
             )

    assert :ok = Reconciler.reconcile_once(root: Spool.spool_root())
    assert Repo.get!(InboundDelivery, delivery.id).raw_storage_state == "spooled"
    assert :ok = Ingest.archive_delivery(delivery.id)
  end

  test "transient spool stat errors do not mark deliveries missing" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])

    assert :ok =
             Reconciler.reconcile_once(
               root: Spool.spool_root(),
               file_stat_fun: fn _path -> {:error, :eacces} end
             )

    assert Repo.get!(InboundDelivery, delivery.id).raw_storage_state == "spooled"

    refute Repo.get_by(MessageEvent,
             inbound_delivery_id: delivery.id,
             event_type: "missing_spool"
           )
  end

  test "stale missing-spool detection cannot downgrade an archived delivery" do
    %{route: route} = route_fixture()
    assert {:ok, stale_delivery} = accept_delivery([route])
    assert :ok = Ingest.archive_delivery(stale_delivery.id)

    assert :ok = Ingest.mark_missing_spool(stale_delivery)

    delivery = Repo.get!(InboundDelivery, stale_delivery.id)
    assert delivery.raw_storage_state == "archived"
    assert delivery.processing_state == "archived"

    refute Repo.get_by(MessageEvent,
             inbound_delivery_id: delivery.id,
             event_type: "missing_spool"
           )
  end

  test "crash boundary: failure before ready rename leaves only partial bundle" do
    %{route: route} = route_fixture()

    assert {:error, %{reason: :before_ready_rename}} =
             Spool.write_bundle(raw_message(), spool_attrs([route]),
               ingest_id: "before-ready",
               fail_at: :before_ready_rename
             )

    refute File.exists?(Path.join([Spool.spool_root(), "ready", "before-ready"]))
    assert File.exists?(Path.join([Spool.spool_root(), "tmp", "before-ready.partial"]))
  end

  test "crash boundary: ready bundle before database commit becomes retained orphan" do
    %{route: route} = route_fixture()

    assert {:error, %{reason: :after_spool_before_accept}} =
             Ingest.accept_transport(
               raw_message(),
               Map.put(spool_attrs([route]), :ingest_id, "ready-before-db"),
               [route],
               fail_at: :after_spool_before_accept
             )

    assert File.exists?(Path.join([Spool.spool_root(), "ready", "ready-before-db"]))
    refute Repo.get_by(InboundDelivery, ingest_id: "ready-before-db")

    assert :ok = Reconciler.reconcile_once(root: Spool.spool_root(), orphan_retention_seconds: 0)
    refute File.exists?(Path.join([Spool.spool_root(), "ready", "ready-before-db"]))
    assert {:ok, [_ | _]} = File.ls(Path.join(Spool.spool_root(), "failed"))
  end

  test "crash boundary: committed database row before archival resumes from job" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])

    assert delivery.raw_storage_state == "spooled"
    assert File.exists?(delivery.spool_bundle_path)
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "crash boundary: raw copy before archived update is safe to retry" do
    %{domain: domain, route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])

    key = RawStore.build_key(domain.id, delivery.received_at, delivery.id)

    assert {:error, %{reason: :after_raw_copy_before_update}} =
             Ingest.archive_delivery(delivery.id, fail_at: :after_raw_copy_before_update)

    assert {:ok, _stat} = RawStore.stat(key)
    assert Repo.get!(InboundDelivery, delivery.id).raw_storage_state == "spooled"

    assert :ok = Ingest.archive_delivery(delivery.id)
    assert Repo.get!(InboundDelivery, delivery.id).raw_storage_state == "archived"
  end

  defp accept_delivery(routes) do
    Ingest.accept_transport(raw_message(), spool_attrs(routes), routes)
  end

  defp route_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "ingest#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_mailbox(domain, %{local_part: "inbox"})
    {:ok, route} = Accounts.resolve_recipient("inbox@#{domain.normalized_domain}")
    %{domain: domain, mailbox: mailbox, route: route}
  end

  defp spool_attrs(routes) do
    %{
      received_at: DateTime.utc_now(),
      peer_ip: "127.0.0.1",
      helo: "sender.example",
      envelope_from: "sender@example.net",
      original_recipients: Enum.map(routes, & &1.original_recipient)
    }
  end

  defp raw_message, do: "Subject: hello\r\n\r\nBody\r\n"
end

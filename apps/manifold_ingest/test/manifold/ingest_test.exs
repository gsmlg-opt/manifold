defmodule Manifold.IngestTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Ingest
  alias Manifold.Ingest.AcceptanceReceipt
  alias Manifold.Ingest.{ExternalAcceptanceReceipt, ExternalSource}
  alias Manifold.Ingest.Jobs.{ArchiveRawEmail, EvaluateInboundSecurity, ProjectInboundMail}
  alias Manifold.Ingest.Reconciler

  alias Manifold.Ingest.Schema.{
    CloudIngressIdentity,
    DeliveryRecipient,
    ExternalIngressIdentity,
    InboundDelivery,
    MessageEvent
  }

  alias Manifold.Mail.Schema.{MailboxEntry, Message}
  alias Manifold.Repo
  alias Manifold.Security.Schema.SecurityAssessment
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
    assert Repo.one!(MailboxEntry).quarantined
    assert Repo.get_by!(MessageEvent, event_type: "accepted")
    assert [%Oban.Job{worker: worker}] = Repo.all(Oban.Job)
    assert worker == inspect(ArchiveRawEmail)
  end

  test "multiple routes preserve all transport recipient records" do
    %{domain: domain, route: first_route} = route_fixture()
    {:ok, second} = Accounts.create_account(domain, %{local_part: "second"})

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

  test "edge acceptance records provenance in the acceptance transaction" do
    %{route: route} = route_fixture()
    bundle = edge_bundle!("edge-first", [route])

    assert {:ok,
            %AcceptanceReceipt{
              source_id: "edge-primary",
              external_delivery_id: "delivery-1",
              existing?: false
            } = receipt} =
             Ingest.accept_edge("edge-primary", "delivery-1", bundle, [route])

    assert receipt.ingest_id == bundle.manifest.ingest_id
    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(CloudIngressIdentity, :count) == 1

    assert {:ok, %AcceptanceReceipt{existing?: true} = existing} =
             Ingest.lookup_ingress("edge-primary", "delivery-1")

    assert existing.inbound_delivery_id == receipt.inbound_delivery_id
    assert existing.raw_sha256 == receipt.raw_sha256
    assert existing.raw_size == receipt.raw_size
    assert existing.routes_sha256 == receipt.routes_sha256
  end

  test "repeated edge import with the same content and routes returns the existing acceptance" do
    %{route: route} = route_fixture()
    first_bundle = edge_bundle!("edge-repeat-first", [route])
    retry_bundle = edge_bundle!("edge-repeat-second", [route])

    assert {:ok, first} =
             Ingest.accept_edge("edge-primary", "delivery-repeat", first_bundle, [route])

    assert {:ok, %AcceptanceReceipt{existing?: true} = retry} =
             Ingest.accept_edge("edge-primary", "delivery-repeat", retry_bundle, [route])

    assert retry.inbound_delivery_id == first.inbound_delivery_id
    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(CloudIngressIdentity, :count) == 1
    assert Repo.aggregate(DeliveryRecipient, :count) == 1
    assert Repo.aggregate(MailboxEntry, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "repeated edge import rejects conflicting content permanently" do
    %{route: route} = route_fixture()
    first_bundle = edge_bundle!("edge-conflict-first", [route])

    conflicting_bundle =
      edge_bundle!("edge-conflict-second", [route], "Subject: changed\r\n\r\nChanged\r\n")

    assert {:ok, _receipt} =
             Ingest.accept_edge("edge-primary", "delivery-conflict", first_bundle, [route])

    assert {:error, %{class: :permanent, reason: :ingress_conflict}} =
             Ingest.accept_edge(
               "edge-primary",
               "delivery-conflict",
               conflicting_bundle,
               [route]
             )

    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(CloudIngressIdentity, :count) == 1
  end

  test "repeated edge import rejects conflicting frozen routes permanently" do
    %{domain: domain, route: route} = route_fixture()
    {:ok, other_mailbox} = Accounts.create_account(domain, %{local_part: "other"})

    conflicting_route = %{
      route
      | canonical_recipient: "other@#{domain.normalized_domain}",
        mailbox_ids: [other_mailbox.id]
    }

    first_bundle = edge_bundle!("edge-routes-first", [route])
    conflicting_bundle = edge_bundle!("edge-routes-second", [conflicting_route])

    assert {:ok, _receipt} =
             Ingest.accept_edge("edge-primary", "delivery-routes", first_bundle, [route])

    assert {:error, %{class: :permanent, reason: :ingress_conflict}} =
             Ingest.accept_edge(
               "edge-primary",
               "delivery-routes",
               conflicting_bundle,
               [conflicting_route]
             )

    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(CloudIngressIdentity, :count) == 1
  end

  test "failed edge acceptance rolls back provenance and can be retried" do
    %{route: route} = route_fixture()
    bundle = edge_bundle!("edge-rollback", [route])

    assert {:error, %{reason: :after_delivery_insert_before_commit}} =
             Ingest.accept_edge(
               "edge-primary",
               "delivery-rollback",
               bundle,
               [route],
               fail_at: :after_delivery_insert_before_commit
             )

    refute Repo.get_by(InboundDelivery, ingest_id: bundle.manifest.ingest_id)
    assert Repo.aggregate(CloudIngressIdentity, :count) == 0

    assert {:ok, %AcceptanceReceipt{existing?: false}} =
             Ingest.accept_edge("edge-primary", "delivery-rollback", bundle, [route])

    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(CloudIngressIdentity, :count) == 1
  end

  test "external import atomically creates a provider delivery without SMTP recipient facts" do
    %{domain: domain, mailbox: mailbox} = route_fixture()
    source = external_source(domain, mailbox, "gmail-message-1")

    assert {:ok,
            %ExternalAcceptanceReceipt{
              provider: "gmail",
              external_message_id: "gmail-message-1",
              existing?: false
            } = receipt} = Ingest.import_external(raw_message(), source)

    delivery = Repo.get!(InboundDelivery, receipt.inbound_delivery_id)
    assert delivery.source_kind == "provider_import"
    assert delivery.storage_domain_id == domain.id
    assert is_nil(delivery.peer_ip)
    assert is_nil(delivery.helo)
    assert is_nil(delivery.envelope_from)
    assert Repo.aggregate(DeliveryRecipient, :count) == 0

    assert %MailboxEntry{
             mailbox_id: mailbox_id,
             inbound_delivery_id: inbound_delivery_id,
             original_recipient: "person@gmail.example"
           } = Repo.one!(MailboxEntry)

    assert mailbox_id == mailbox.id
    assert inbound_delivery_id == delivery.id
    assert Repo.get_by!(MessageEvent, inbound_delivery_id: delivery.id, event_type: "accepted")
    assert Repo.get_by!(ExternalIngressIdentity, inbound_delivery_id: delivery.id)
    assert Repo.get_by!(Oban.Job, worker: inspect(ArchiveRawEmail))

    detail = Ingest.get_delivery_detail!(delivery.id)
    assert Enum.map(detail.mailboxes, & &1.id) == [mailbox.id]
  end

  test "repeated external import returns the same durable receipt" do
    %{domain: domain, mailbox: mailbox} = route_fixture()
    source = external_source(domain, mailbox, "gmail-message-repeat")

    assert {:ok, first} = Ingest.import_external(raw_message(), source)

    assert {:ok, %ExternalAcceptanceReceipt{existing?: true} = repeated} =
             Ingest.import_external(raw_message(), source)

    assert repeated.inbound_delivery_id == first.inbound_delivery_id
    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(ExternalIngressIdentity, :count) == 1
    assert Repo.aggregate(MailboxEntry, :count) == 1
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "external acceptance can be recovered by trusted provider identity" do
    %{domain: domain, mailbox: mailbox} = route_fixture()
    source = external_source(domain, mailbox, "gmail-message-lookup")

    assert {:ok, first} = Ingest.import_external(raw_message(), source)

    assert {:ok, %ExternalAcceptanceReceipt{existing?: true} = recovered} =
             Ingest.lookup_external(
               source.provider,
               source.account_id,
               source.external_message_id
             )

    assert recovered.inbound_delivery_id == first.inbound_delivery_id

    assert {:error, %{class: :permanent, reason: :external_ingress_not_found}} =
             Ingest.lookup_external(source.provider, source.account_id, "missing")
  end

  test "external identity rejects changed content or target mailbox" do
    %{domain: domain, mailbox: mailbox} = route_fixture()
    {:ok, other_mailbox} = Accounts.create_account(domain, %{local_part: "external-other"})
    source = external_source(domain, mailbox, "gmail-message-conflict")

    assert {:ok, _receipt} = Ingest.import_external(raw_message(), source)

    assert {:error, %{class: :permanent, reason: :external_ingress_conflict}} =
             Ingest.import_external("Subject: changed\r\n\r\nChanged\r\n", source)

    assert {:error, %{class: :permanent, reason: :external_ingress_conflict}} =
             Ingest.import_external(
               raw_message(),
               %{source | mailbox_id: other_mailbox.id}
             )

    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(ExternalIngressIdentity, :count) == 1
  end

  test "external import rejects inactive mailbox destinations" do
    %{domain: domain, mailbox: mailbox} = route_fixture()
    source = external_source(domain, mailbox, "gmail-message-disabled")

    mailbox
    |> Ecto.Changeset.change(active: false)
    |> Repo.update!()

    assert {:error, %{class: :permanent, reason: :mailbox_not_active}} =
             Ingest.import_external(raw_message(), source)

    assert Repo.aggregate(InboundDelivery, :count) == 0
  end

  test "external acceptance failure leaves a ready orphan and no logical acceptance" do
    %{domain: domain, mailbox: mailbox} = route_fixture()
    source = external_source(domain, mailbox, "gmail-message-rollback")

    assert {:error, %{reason: :after_delivery_insert_before_commit}} =
             Ingest.import_external(raw_message(), source,
               fail_at: :after_delivery_insert_before_commit
             )

    assert Repo.aggregate(InboundDelivery, :count) == 0
    assert Repo.aggregate(ExternalIngressIdentity, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert File.dir?(Path.join([Spool.spool_root(), "ready", source.ingest_id]))
  end

  test "external ready reuse binds manifest version and ingest ID to its directory" do
    %{domain: domain, mailbox: mailbox} = route_fixture()
    source = external_source(domain, mailbox, "gmail-message-ready-binding")

    assert {:error, %{reason: :after_delivery_insert_before_commit}} =
             Ingest.import_external(raw_message(), source,
               fail_at: :after_delivery_insert_before_commit
             )

    manifest_path =
      Path.join([Spool.spool_root(), "ready", source.ingest_id, "manifest.json"])

    manifest =
      manifest_path
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("version", 1)
      |> Map.put("ingest_id", "different-ingest-id")

    File.write!(manifest_path, Jason.encode!(manifest))

    assert {:error, %{class: :permanent, reason: :external_ready_conflict}} =
             Ingest.import_external(raw_message(), source)

    assert Repo.aggregate(InboundDelivery, :count) == 0
  end

  test "external delivery archives through its trusted storage domain without recipients" do
    %{domain: domain, mailbox: mailbox} = route_fixture()
    source = external_source(domain, mailbox, "gmail-message-archive")

    assert {:ok, receipt} = Ingest.import_external(raw_message(), source)
    assert :ok = Ingest.archive_delivery(receipt.inbound_delivery_id)

    delivery = Repo.get!(InboundDelivery, receipt.inbound_delivery_id)
    assert delivery.raw_storage_state == "archived"
    assert String.starts_with?(delivery.raw_object_key, "raw/#{domain.id}/")
    assert Repo.aggregate(DeliveryRecipient, :count) == 0
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

  test "archival commits projection and security jobs before projection completes" do
    parser_version = Application.fetch_env!(:manifold_mail, :parser_version)
    sanitizer_version = Application.fetch_env!(:manifold_mail, :sanitizer_version)
    evaluation_version = Application.fetch_env!(:manifold_security, :evaluation_version)

    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])

    assert :ok = Ingest.archive_delivery(delivery.id)

    assert %Oban.Job{} =
             Repo.get_by(Oban.Job,
               worker: inspect(ProjectInboundMail),
               args: %{
                 "inbound_delivery_id" => delivery.id,
                 "parser_version" => parser_version,
                 "sanitizer_version" => sanitizer_version
               }
             )

    assert %Oban.Job{} =
             Repo.get_by(Oban.Job,
               worker: inspect(EvaluateInboundSecurity),
               args: %{
                 "inbound_delivery_id" => delivery.id,
                 "evaluation_version" => evaluation_version
               }
             )

    assert :ok =
             ProjectInboundMail.perform(%Oban.Job{
               args: %{
                 "inbound_delivery_id" => delivery.id,
                 "parser_version" => parser_version,
                 "sanitizer_version" => sanitizer_version
               }
             })

    projected = Repo.get!(InboundDelivery, delivery.id)
    assert projected.processing_state == "processed"
    assert Repo.get_by!(Message, inbound_delivery_id: delivery.id)
    assert Repo.get_by!(MailboxEntry, inbound_delivery_id: delivery.id).message_id
    assert Repo.get_by!(MessageEvent, inbound_delivery_id: delivery.id, event_type: "parsed")
  end

  test "security worker releases an allowed delivery only after policy commits" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])
    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: delivery.id)
    assert entry.quarantined

    assert :ok = Ingest.archive_delivery(delivery.id)

    assert :ok =
             EvaluateInboundSecurity.perform(%Oban.Job{
               args: %{
                 "inbound_delivery_id" => delivery.id,
                 "evaluation_version" => 1
               }
             })

    refute Repo.get!(MailboxEntry, entry.id).quarantined

    assessment =
      Repo.get_by!(SecurityAssessment, inbound_delivery_id: delivery.id)

    assert assessment.policy_action == "allow"
    assert assessment.policy_applied
  end

  test "assessment commit before visibility update remains fail closed and retries" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])
    assert :ok = Ingest.archive_delivery(delivery.id)

    assert {:error, %{reason: :after_assessment_before_policy}} =
             Ingest.evaluate_security(delivery.id,
               fail_at: :after_assessment_before_policy,
               evaluation_version: 1
             )

    assessment =
      Repo.get_by!(SecurityAssessment, inbound_delivery_id: delivery.id)

    refute assessment.policy_applied
    assert Repo.get_by!(MailboxEntry, inbound_delivery_id: delivery.id).quarantined

    assert :ok = Ingest.evaluate_security(delivery.id, evaluation_version: 1)
    refute Repo.get_by!(MailboxEntry, inbound_delivery_id: delivery.id).quarantined
    assert Repo.get!(SecurityAssessment, assessment.id).policy_applied
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

  test "reconciliation restores missing security work until policy is applied" do
    %{route: route} = route_fixture()
    assert {:ok, delivery} = accept_delivery([route])
    assert :ok = Ingest.archive_delivery(delivery.id)

    EvaluateInboundSecurity
    |> inspect()
    |> then(fn worker ->
      from(job in Oban.Job, where: job.worker == ^worker)
    end)
    |> Repo.delete_all()

    assert :ok = Reconciler.reconcile_once(root: Spool.spool_root())

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == ^inspect(EvaluateInboundSecurity) and
                   fragment("?->>'inbound_delivery_id' = ?", job.args, ^delivery.id)
             ),
             :count
           ) == 1

    assert :ok = Ingest.evaluate_security(delivery.id)

    EvaluateInboundSecurity
    |> inspect()
    |> then(fn worker ->
      from(job in Oban.Job, where: job.worker == ^worker)
    end)
    |> Repo.delete_all()

    assert :ok = Reconciler.reconcile_once(root: Spool.spool_root())

    assert Repo.aggregate(
             from(job in Oban.Job, where: job.worker == ^inspect(EvaluateInboundSecurity)),
             :count
           ) == 0
  end

  test "reconciliation schedules the exact upgraded projection beside stale active work" do
    old_parser_version = Application.fetch_env!(:manifold_mail, :parser_version)
    old_sanitizer_version = Application.fetch_env!(:manifold_mail, :sanitizer_version)

    on_exit(fn ->
      Application.put_env(:manifold_mail, :parser_version, old_parser_version)
      Application.put_env(:manifold_mail, :sanitizer_version, old_sanitizer_version)
    end)

    Application.put_env(:manifold_mail, :parser_version, 1)
    Application.put_env(:manifold_mail, :sanitizer_version, 1)

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

  defp edge_bundle!(ingest_id, routes, raw \\ raw_message()) do
    assert {:ok, bundle} =
             Spool.write_bundle(
               raw,
               Map.put(spool_attrs(routes), :routes, routes),
               ingest_id: ingest_id
             )

    bundle
  end

  defp route_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "ingest#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})
    {:ok, route} = Accounts.resolve_recipient("inbox@#{domain.normalized_domain}")
    %{domain: domain, mailbox: mailbox, route: route}
  end

  defp external_source(domain, mailbox, message_id) do
    %ExternalSource{
      provider: "gmail",
      account_id: Ecto.UUID.generate(),
      external_message_id: message_id,
      mailbox_id: mailbox.id,
      storage_domain_id: domain.id,
      recipient_address: "person@gmail.example",
      received_at: DateTime.utc_now(),
      ingest_id: "gmail-" <> Ecto.UUID.generate()
    }
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

defmodule Manifold.MailTest do
  use Manifold.DataCase, async: true

  import Ecto.Query

  alias Manifold.Ingest.Schema.InboundDelivery
  alias Manifold.Mail

  alias Manifold.Mail.Schema.{
    Attachment,
    Folder,
    MailboxEntry,
    Message,
    Thread
  }

  alias Manifold.Repo

  test "mailbox copy cleanup preserves a shared projected delivery" do
    %{domain_id: domain_id, mailbox_ids: [first_id, second_id]} = mailbox_fixtures(2)
    delivery = delivery_fixture(domain_id)
    message = message_fixture(delivery.id)
    first_projection = projection_fixture(first_id, delivery.id, message.id)
    second_projection = projection_fixture(second_id, delivery.id, message.id)
    attachment = attachment_fixture(message.id, "1")

    assert %{ids: [delivery_id], done?: true} =
             Mail.list_account_delivery_ids(first_id, nil, 250)

    assert delivery_id == delivery.id
    assert Mail.delivery_owned?(delivery.id)
    assert Mail.account_data_remaining?(first_id)

    assert %{deleted: 1, done?: true} = Mail.delete_mailbox_entries_batch(first_id, 250)

    refute Repo.exists?(from(entry in MailboxEntry, where: entry.mailbox_id == ^first_id))
    assert Repo.get!(MailboxEntry, second_projection.entry.id)
    assert Repo.get!(Message, message.id)
    assert Repo.get!(Attachment, attachment.id)
    assert Repo.get!(Folder, first_projection.folder.id)
    assert Repo.get!(Folder, second_projection.folder.id)
    assert Repo.get!(Thread, first_projection.thread.id)
    assert Repo.get!(Thread, second_projection.thread.id)
    assert Mail.delivery_owned?(delivery.id)
    refute Mail.account_data_remaining?(first_id)
    assert Mail.account_data_remaining?(second_id)
  end

  test "mailbox delivery listing is UUID ordered, cursor paged, isolated, and exact-page aware" do
    %{domain_id: domain_id, mailbox_ids: [mailbox_id, other_mailbox_id]} = mailbox_fixtures(2)

    deliveries =
      for _index <- 1..3 do
        delivery = delivery_fixture(domain_id)
        mailbox_entry_fixture(mailbox_id, delivery.id)
        delivery
      end

    shared = hd(deliveries)
    mailbox_entry_fixture(other_mailbox_id, shared.id)

    other_delivery = delivery_fixture(domain_id)
    mailbox_entry_fixture(other_mailbox_id, other_delivery.id)

    expected_ids = deliveries |> Enum.map(& &1.id) |> Enum.sort()
    [first_id, second_id, third_id] = expected_ids

    assert %{ids: [^first_id, ^second_id], done?: false} =
             Mail.list_account_delivery_ids(mailbox_id, nil, 2)

    assert %{ids: [^second_id, ^third_id], done?: true} =
             Mail.list_account_delivery_ids(mailbox_id, first_id, 2)

    assert %{ids: [], done?: true} =
             Mail.list_account_delivery_ids(mailbox_id, third_id, 2)

    assert %{ids: other_ids, done?: true} =
             Mail.list_account_delivery_ids(other_mailbox_id, nil, 10)

    assert Enum.sort(other_ids) == Enum.sort([shared.id, other_delivery.id])
  end

  test "mailbox entry deletion is deterministic, bounded, exact-page aware, and isolated" do
    %{domain_id: domain_id, mailbox_ids: [mailbox_id, other_mailbox_id]} = mailbox_fixtures(2)

    entries =
      for _index <- 1..4 do
        delivery = delivery_fixture(domain_id)
        mailbox_entry_fixture(mailbox_id, delivery.id)
      end

    shared_entry = hd(entries)
    other_entry = mailbox_entry_fixture(other_mailbox_id, shared_entry.inbound_delivery_id)

    expected_ids = entries |> Enum.map(& &1.id) |> Enum.sort()
    [first_id, second_id, third_id, fourth_id] = expected_ids

    assert %{deleted: 2, done?: false} = Mail.delete_mailbox_entries_batch(mailbox_id, 2)

    refute Repo.get(MailboxEntry, first_id)
    refute Repo.get(MailboxEntry, second_id)
    assert Repo.get!(MailboxEntry, third_id)
    assert Repo.get!(MailboxEntry, fourth_id)
    assert Repo.get!(MailboxEntry, other_entry.id)

    assert %{deleted: 2, done?: true} = Mail.delete_mailbox_entries_batch(mailbox_id, 2)
    refute Mail.account_data_remaining?(mailbox_id)
    assert Mail.account_data_remaining?(other_mailbox_id)
  end

  test "shared attachment blobs stay referenced until the final attachment is removed" do
    %{domain_id: domain_id} = mailbox_fixtures(1)
    first_delivery = delivery_fixture(domain_id)
    second_delivery = delivery_fixture(domain_id)
    first_message = message_fixture(first_delivery.id)
    second_message = message_fixture(second_delivery.id)
    shared_key = object_key(String.duplicate("a", 64))

    first_attachment = attachment_fixture(first_message.id, "1", shared_key)
    duplicate_attachment = attachment_fixture(first_message.id, "2", shared_key)
    second_attachment = attachment_fixture(second_message.id, "1", shared_key)

    assert [^shared_key] = Mail.attachment_object_keys(Repo, first_delivery.id)
    assert [^shared_key] = Mail.attachment_object_keys(Repo, second_delivery.id)
    assert [] = Mail.attachment_object_keys(Repo, Ecto.UUID.generate())
    assert Mail.blob_referenced?(shared_key)
    refute Mail.blob_referenced?(nil)

    Repo.delete!(first_delivery)

    refute Repo.get(Message, first_message.id)
    refute Repo.get(Attachment, first_attachment.id)
    refute Repo.get(Attachment, duplicate_attachment.id)
    assert Repo.get!(Attachment, second_attachment.id)
    assert Mail.blob_referenced?(shared_key)

    Repo.delete!(second_attachment)

    refute Mail.blob_referenced?(shared_key)
    assert Repo.get!(Message, second_message.id)
    assert Repo.get!(InboundDelivery, second_delivery.id)
  end

  test "mail cleanup probes have concurrent supporting indexes" do
    migration_path =
      Path.expand(
        "../../../manifold_data/priv/repo/migrations/20260811000300_add_attachment_object_key_index.exs",
        __DIR__
      )

    assert File.exists?(migration_path)
    migration = Manifold.Repo.Migrations.AddAttachmentObjectKeyIndex
    unless Code.ensure_loaded?(migration), do: Code.require_file(migration_path)

    assert [disable_ddl_transaction: true, disable_migration_lock: true] =
             apply(migration, :__migration__, [])

    source = File.read!(migration_path)
    assert source =~ "index(:attachments, [:object_key], concurrently: true)"
    assert source =~ "index(:mailbox_entries, [:mailbox_id, :id], concurrently: true)"
    assert length(Regex.scan(~r/concurrently:\s*true/, source)) == 2

    expected_indexes = [
      "attachments_object_key_index",
      "mailbox_entries_mailbox_id_id_index"
    ]

    assert indexes =
             Repo.query!(
               """
               SELECT indexname, indexdef
               FROM pg_indexes
               WHERE schemaname = current_schema()
                 AND indexname = ANY($1)
               ORDER BY indexname
               """,
               [expected_indexes]
             ).rows

    assert Enum.map(indexes, &hd/1) == expected_indexes
    assert Enum.at(indexes, 0) |> Enum.at(1) =~ "(object_key)"
    assert Enum.at(indexes, 1) |> Enum.at(1) =~ "(mailbox_id, id)"

    Repo.query!("SET LOCAL enable_seqscan = off")

    blob_plan =
      Repo.query!(
        """
        EXPLAIN (COSTS OFF)
        SELECT 1
        FROM attachments
        WHERE object_key = $1
        LIMIT 1
        """,
        [object_key(String.duplicate("f", 64))]
      ).rows
      |> List.flatten()
      |> Enum.join("\n")

    mailbox_plan =
      Repo.query!(
        """
        EXPLAIN (COSTS OFF)
        SELECT id
        FROM mailbox_entries
        WHERE mailbox_id = $1
        ORDER BY id
        LIMIT 250
        """,
        [Ecto.UUID.dump!(Ecto.UUID.generate())]
      ).rows
      |> List.flatten()
      |> Enum.join("\n")

    assert blob_plan =~ "attachments_object_key_index"
    assert mailbox_plan =~ "mailbox_entries_mailbox_id_id_index"
  end

  defp mailbox_fixtures(count) do
    now = DateTime.utc_now()
    domain_id = Ecto.UUID.generate()
    suffix = System.unique_integer([:positive])
    domain = "mail-cleanup-#{suffix}.test"

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

    mailbox_ids = Enum.map(1..count, fn _index -> Ecto.UUID.generate() end)

    mailbox_rows =
      mailbox_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {mailbox_id, index} ->
        %{
          id: Ecto.UUID.dump!(mailbox_id),
          domain_id: Ecto.UUID.dump!(domain_id),
          local_part: "mailbox#{index}",
          canonical_local_part: "mailbox#{index}",
          active: true,
          plus_addressing_enabled: true,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all("mailboxes", mailbox_rows)
    %{domain_id: domain_id, mailbox_ids: mailbox_ids}
  end

  defp delivery_fixture(domain_id) do
    now = DateTime.utc_now()
    delivery_id = Ecto.UUID.generate()

    Repo.insert_all("inbound_deliveries", [
      %{
        id: Ecto.UUID.dump!(delivery_id),
        ingest_id: Ecto.UUID.generate(),
        source_kind: "provider_import",
        storage_domain_id: Ecto.UUID.dump!(domain_id),
        received_at: now,
        raw_size: 1,
        raw_sha256: String.duplicate("0", 64),
        spool_bundle_path: "/removed",
        raw_storage_state: "archived",
        processing_state: "processed",
        inserted_at: now,
        updated_at: now
      }
    ])

    Repo.get!(InboundDelivery, delivery_id)
  end

  defp message_fixture(delivery_id) do
    %Message{}
    |> Message.changeset(%{
      inbound_delivery_id: delivery_id,
      rfc_message_id: "<#{delivery_id}@example.test>",
      subject: "Mailbox cleanup",
      parser_version: 1,
      sanitizer_version: 1,
      parse_state: "parsed"
    })
    |> Repo.insert!()
  end

  defp projection_fixture(mailbox_id, delivery_id, message_id) do
    now = DateTime.utc_now()

    folder =
      %Folder{}
      |> Folder.changeset(%{mailbox_id: mailbox_id, kind: "inbox", name: "Inbox"})
      |> Repo.insert!()

    thread =
      %Thread{}
      |> Thread.changeset(%{
        mailbox_id: mailbox_id,
        subject_summary: "Mailbox cleanup",
        last_message_at: now,
        message_count: 1
      })
      |> Repo.insert!()

    entry = mailbox_entry_fixture(mailbox_id, delivery_id, message_id, folder.id, thread.id)
    %{entry: entry, folder: folder, thread: thread}
  end

  defp mailbox_entry_fixture(
         mailbox_id,
         delivery_id,
         message_id \\ nil,
         folder_id \\ nil,
         thread_id \\ nil
       ) do
    %MailboxEntry{}
    |> MailboxEntry.changeset(%{
      mailbox_id: mailbox_id,
      inbound_delivery_id: delivery_id,
      message_id: message_id,
      folder_id: folder_id,
      thread_id: thread_id,
      original_recipient: "inbox@example.test",
      quarantined: false
    })
    |> Repo.insert!()
  end

  defp attachment_fixture(message_id, part_path, key \\ nil) do
    sha256 = if key, do: Path.basename(key), else: String.duplicate("b", 64)

    %Attachment{}
    |> Attachment.changeset(%{
      message_id: message_id,
      part_path: part_path,
      media_type: "application/octet-stream",
      disposition: "attachment",
      size: 1,
      sha256: sha256,
      object_key: key || object_key(sha256)
    })
    |> Repo.insert!()
  end

  defp object_key(sha256), do: "blobs/sha256/#{String.slice(sha256, 0, 2)}/#{sha256}"
end

defmodule Manifold.MailConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Manifold.Mail
  alias Manifold.Mail.Schema.MailboxEntry
  alias Manifold.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    fixture = concurrency_fixture()

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        cleanup_concurrency_fixture(fixture)
      after
        Sandbox.checkin(Repo)
      end
    end)

    {:ok, fixture: fixture}
  end

  test "concurrent mailbox cleanup workers skip locked batches without leakage", %{
    fixture: fixture
  } do
    %{mailbox_id: mailbox_id, other_mailbox_id: other_mailbox_id} = fixture
    [first_id, second_id, third_id, fourth_id, fifth_id, sixth_id] = fixture.entry_ids
    test_pid = self()
    barrier_ref = make_ref()

    first_worker =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          Repo.transaction(fn ->
            result = Mail.delete_mailbox_entries_batch(mailbox_id, 2)
            send(test_pid, {:first_batch_deleted, self(), barrier_ref, result})

            receive do
              {:commit_first_batch, ^barrier_ref} -> result
            after
              5_000 -> raise "timed out waiting to commit first mailbox cleanup batch"
            end
          end)
        after
          Sandbox.checkin(Repo)
        end
      end)

    first_worker_pid = first_worker.pid

    try do
      assert_receive {:first_batch_deleted, ^first_worker_pid, ^barrier_ref,
                      %{deleted: 2, done?: false}},
                     5_000

      second_worker =
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            Mail.delete_mailbox_entries_batch(mailbox_id, 2)
          after
            Sandbox.checkin(Repo)
          end
        end)

      assert %{deleted: 2, done?: false} = Task.await(second_worker, 5_000)

      assert Repo.get!(MailboxEntry, first_id)
      assert Repo.get!(MailboxEntry, second_id)
      refute Repo.get(MailboxEntry, third_id)
      refute Repo.get(MailboxEntry, fourth_id)
      assert Repo.get!(MailboxEntry, fifth_id)
      assert Repo.get!(MailboxEntry, sixth_id)

      send(first_worker_pid, {:commit_first_batch, barrier_ref})
      assert {:ok, %{deleted: 2, done?: false}} = Task.await(first_worker, 5_000)

      refute Repo.get(MailboxEntry, first_id)
      refute Repo.get(MailboxEntry, second_id)
      refute Repo.get(MailboxEntry, third_id)
      refute Repo.get(MailboxEntry, fourth_id)
      assert Repo.get!(MailboxEntry, fifth_id)
      assert Repo.get!(MailboxEntry, sixth_id)

      assert %{deleted: 2, done?: true} = Mail.delete_mailbox_entries_batch(mailbox_id, 250)
      refute Mail.account_data_remaining?(mailbox_id)
      assert Repo.get!(MailboxEntry, fixture.other_entry_id)
      assert Mail.account_data_remaining?(other_mailbox_id)

      cleanup_concurrency_fixture(fixture)
      assert [] = Repo.all(from(entry in MailboxEntry, where: entry.id in ^fixture.all_entry_ids))

      assert [] =
               Repo.query!("SELECT id FROM inbound_deliveries WHERE id = ANY($1)", [
                 Enum.map(fixture.delivery_ids, &Ecto.UUID.dump!/1)
               ]).rows

      assert [] =
               Repo.query!("SELECT id FROM mailboxes WHERE id = ANY($1)", [
                 Enum.map([mailbox_id, other_mailbox_id], &Ecto.UUID.dump!/1)
               ]).rows

      assert [] =
               Repo.query!("SELECT id FROM domains WHERE id = $1", [
                 Ecto.UUID.dump!(fixture.domain_id)
               ]).rows
    after
      send(first_worker_pid, {:commit_first_batch, barrier_ref})
    end
  end

  defp concurrency_fixture do
    now = DateTime.utc_now()
    domain_id = Ecto.UUID.generate()
    mailbox_id = Ecto.UUID.generate()
    other_mailbox_id = Ecto.UUID.generate()
    domain = "mail-cleanup-race-#{Ecto.UUID.generate()}.test"

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
      mailbox_row(mailbox_id, domain_id, "target", now),
      mailbox_row(other_mailbox_id, domain_id, "other", now)
    ])

    delivery_ids = Enum.map(1..7, fn _index -> Ecto.UUID.generate() end)

    Repo.insert_all(
      "inbound_deliveries",
      Enum.map(delivery_ids, &delivery_row(&1, domain_id, now))
    )

    target_rows =
      delivery_ids
      |> Enum.take(6)
      |> Enum.map(&mailbox_entry_row(Ecto.UUID.generate(), mailbox_id, &1, now))

    other_row =
      mailbox_entry_row(
        Ecto.UUID.generate(),
        other_mailbox_id,
        List.last(delivery_ids),
        now
      )

    Repo.insert_all("mailbox_entries", target_rows ++ [other_row])

    entry_ids = target_rows |> Enum.map(&Ecto.UUID.load!(&1.id)) |> Enum.sort()
    other_entry_id = Ecto.UUID.load!(other_row.id)

    %{
      domain_id: domain_id,
      mailbox_id: mailbox_id,
      other_mailbox_id: other_mailbox_id,
      delivery_ids: delivery_ids,
      entry_ids: entry_ids,
      other_entry_id: other_entry_id,
      all_entry_ids: entry_ids ++ [other_entry_id]
    }
  end

  defp mailbox_row(mailbox_id, domain_id, local_part, now) do
    %{
      id: Ecto.UUID.dump!(mailbox_id),
      domain_id: Ecto.UUID.dump!(domain_id),
      local_part: local_part,
      canonical_local_part: local_part,
      active: true,
      plus_addressing_enabled: true,
      inserted_at: now,
      updated_at: now
    }
  end

  defp delivery_row(delivery_id, domain_id, now) do
    %{
      id: Ecto.UUID.dump!(delivery_id),
      ingest_id: Ecto.UUID.generate(),
      source_kind: "provider_import",
      storage_domain_id: Ecto.UUID.dump!(domain_id),
      received_at: now,
      raw_size: 1,
      raw_sha256: String.duplicate("0", 64),
      spool_bundle_path: "/removed",
      raw_storage_state: "archived",
      processing_state: "processed",
      inserted_at: now,
      updated_at: now
    }
  end

  defp mailbox_entry_row(entry_id, mailbox_id, delivery_id, now) do
    %{
      id: Ecto.UUID.dump!(entry_id),
      mailbox_id: Ecto.UUID.dump!(mailbox_id),
      inbound_delivery_id: Ecto.UUID.dump!(delivery_id),
      original_recipient: "inbox@example.test",
      quarantined: false,
      inserted_at: now,
      updated_at: now
    }
  end

  defp cleanup_concurrency_fixture(fixture) do
    MailboxEntry
    |> where([entry], entry.id in ^fixture.all_entry_ids)
    |> Repo.delete_all()

    Repo.query!("DELETE FROM inbound_deliveries WHERE id = ANY($1)", [
      Enum.map(fixture.delivery_ids, &Ecto.UUID.dump!/1)
    ])

    Repo.query!("DELETE FROM mailboxes WHERE id = ANY($1)", [
      Enum.map([fixture.mailbox_id, fixture.other_mailbox_id], &Ecto.UUID.dump!/1)
    ])

    Repo.query!("DELETE FROM domains WHERE id = $1", [Ecto.UUID.dump!(fixture.domain_id)])
  end
end

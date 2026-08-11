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

  test "attachment object-key discovery is cursor bounded without storing an object key cursor" do
    %{domain_id: domain_id} = mailbox_fixtures(1)
    delivery = delivery_fixture(domain_id)
    message = message_fixture(delivery.id)

    keys =
      for index <- 1..251 do
        digest = :crypto.hash(:sha256, Integer.to_string(index)) |> Base.encode16(case: :lower)
        key = object_key(digest)
        attachment_fixture(message.id, Integer.to_string(index), key)
        key
      end

    assert %{keys: first, next: cursor, done?: false} =
             Mail.attachment_object_keys_batch(Repo, delivery.id, nil, 250)

    assert length(first) == 250
    assert is_binary(cursor)
    refute cursor in keys

    assert %{keys: second, next: _last_cursor, done?: true} =
             Mail.attachment_object_keys_batch(Repo, delivery.id, cursor, 250)

    assert Enum.sort(first ++ second) == Enum.sort(keys)
  end

  test "mail cleanup indexes are valid, ready, ordered, and retry-aware" do
    attachment_migration_path =
      Path.expand(
        "../../../manifold_data/priv/repo/migrations/20260811000300_add_attachment_object_key_index.exs",
        __DIR__
      )

    mailbox_migration_path =
      Path.expand(
        "../../../manifold_data/priv/repo/migrations/20260811000400_add_mailbox_entry_cleanup_index.exs",
        __DIR__
      )

    assert File.exists?(attachment_migration_path)
    assert File.exists?(mailbox_migration_path)

    attachment_migration = Manifold.Repo.Migrations.AddAttachmentObjectKeyIndex

    unless Code.ensure_loaded?(attachment_migration),
      do: Code.require_file(attachment_migration_path)

    mailbox_migration = Manifold.Repo.Migrations.AddMailboxEntryCleanupIndex

    unless Code.ensure_loaded?(mailbox_migration),
      do: Code.require_file(mailbox_migration_path)

    assert [disable_ddl_transaction: true, disable_migration_lock: true] =
             apply(attachment_migration, :__migration__, [])

    assert [disable_ddl_transaction: true, disable_migration_lock: true] =
             apply(mailbox_migration, :__migration__, [])

    attachment_source = File.read!(attachment_migration_path)
    assert attachment_source =~ "index(:attachments, [:object_key], concurrently: true)"
    refute attachment_source =~ "mailbox_entries"
    assert length(Regex.scan(~r/concurrently:\s*true/, attachment_source)) == 1

    mailbox_source = File.read!(mailbox_migration_path)
    create_source = "create(index(:mailbox_entries, [:mailbox_id, :id], concurrently: true))"

    drop_source =
      "drop_if_exists(index(:mailbox_entries, [:mailbox_id, :id], concurrently: true))"

    assert mailbox_source =~ create_source
    refute mailbox_source =~ "create_if_not_exists("
    assert mailbox_source =~ "drop_if_exists("
    assert mailbox_source =~ "def up"
    assert mailbox_source =~ "def down"

    {drop_position, _length} = :binary.match(mailbox_source, drop_source)
    {create_position, _length} = :binary.match(mailbox_source, create_source)
    assert drop_position < create_position

    expected_indexes = [
      "attachments_object_key_index",
      "mailbox_entries_mailbox_id_id_index"
    ]

    assert indexes =
             Repo.query!(
               """
               SELECT index_class.relname,
                      index_meta.indisvalid,
                      index_meta.indisready,
                      ARRAY(
                        SELECT attribute.attname
                        FROM unnest(index_meta.indkey)
                             WITH ORDINALITY AS key(attnum, position)
                        JOIN pg_attribute AS attribute
                          ON attribute.attrelid = table_class.oid
                         AND attribute.attnum = key.attnum
                        WHERE key.position <= index_meta.indnkeyatts
                        ORDER BY key.position
                      ),
                      pg_get_expr(index_meta.indpred, index_meta.indrelid)
               FROM pg_index AS index_meta
               JOIN pg_class AS index_class ON index_class.oid = index_meta.indexrelid
               JOIN pg_class AS table_class ON table_class.oid = index_meta.indrelid
               JOIN pg_namespace AS namespace ON namespace.oid = table_class.relnamespace
               WHERE namespace.nspname = current_schema()
                 AND index_class.relname = ANY($1)
               ORDER BY index_class.relname
               """,
               [expected_indexes]
             ).rows

    assert indexes == [
             ["attachments_object_key_index", true, true, ["object_key"], nil],
             ["mailbox_entries_mailbox_id_id_index", true, true, ["mailbox_id", "id"], nil]
           ]
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

defmodule Manifold.MailBlobPublicationConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
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

  test "blob cleanup waits for publication commit and then retains the referenced blob", %{
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

    cleanup =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          Repo.transaction(fn ->
            [[backend_pid]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(test_pid, {:cleanup_started, self(), backend_pid, barrier_ref})
            :ok = Mail.lock_blob_object_keys(Repo, [fixture.blob_key])
            referenced? = Mail.blob_referenced?(fixture.blob_key)
            if not referenced?, do: :ok = BlobStore.delete(fixture.blob_key)
            referenced?
          end)
        after
          Sandbox.checkin(Repo)
        end
      end)

    cleanup_pid = cleanup.pid
    assert_receive {:cleanup_started, ^cleanup_pid, cleanup_backend_pid, ^barrier_ref}, 5_000
    assert_advisory_wait(cleanup_backend_pid, 5_000)

    send(publisher_pid, {:commit_projection, barrier_ref})
    assert {:ok, %{state: :parsed}} = Task.await(publisher, 5_000)
    assert {:ok, true} = Task.await(cleanup, 5_000)

    assert Repo.get_by!(Attachment, object_key: fixture.blob_key)
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
          flunk("cleanup did not block on the blob advisory lock")
        end
    end)
  end

  defp publication_fixture(tmp_dir) do
    now = DateTime.utc_now()
    domain_id = Ecto.UUID.generate()
    mailbox_id = Ecto.UUID.generate()
    delivery_id = Ecto.UUID.generate()
    domain = "blob-race-#{domain_id}.test"
    attachment = "serialized publication #{delivery_id}"
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
        active: true,
        plus_addressing_enabled: true,
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

    %{
      domain_id: domain_id,
      mailbox_id: mailbox_id,
      delivery_id: delivery_id,
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
      "Subject: Blob race\r\n" <>
      "Message-ID: <blob-race@example.test>\r\n" <>
      "Content-Type: multipart/mixed; boundary=race\r\n\r\n" <>
      "--race\r\nContent-Type: text/plain\r\n\r\nBody\r\n" <>
      "--race\r\nContent-Type: application/octet-stream; name=blob.bin\r\n" <>
      "Content-Disposition: attachment; filename=blob.bin\r\n" <>
      "Content-Transfer-Encoding: base64\r\n\r\n" <>
      Base.encode64(attachment) <>
      "\r\n--race--\r\n"
  end
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
    fixture = concurrency_fixture_ids()

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        cleanup_concurrency_fixture(fixture)
      after
        Sandbox.checkin(Repo)
      end
    end)

    insert_concurrency_fixture(fixture)

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

  test "committed fixture cleanup tolerates a partial setup" do
    partial_fixture = concurrency_fixture_ids()

    Repo.insert_all("domains", [domain_row(partial_fixture, DateTime.utc_now())])
    cleanup_concurrency_fixture(partial_fixture)

    assert [] =
             Repo.query!("SELECT id FROM domains WHERE id = $1", [
               Ecto.UUID.dump!(partial_fixture.domain_id)
             ]).rows
  end

  defp concurrency_fixture_ids do
    domain_id = Ecto.UUID.generate()
    mailbox_id = Ecto.UUID.generate()
    other_mailbox_id = Ecto.UUID.generate()
    delivery_ids = Enum.map(1..7, fn _index -> Ecto.UUID.generate() end)
    entry_ids = Enum.map(1..6, fn _index -> Ecto.UUID.generate() end) |> Enum.sort()
    other_entry_id = Ecto.UUID.generate()

    %{
      domain_id: domain_id,
      domain: "mail-cleanup-race-#{Ecto.UUID.generate()}.test",
      mailbox_id: mailbox_id,
      other_mailbox_id: other_mailbox_id,
      delivery_ids: delivery_ids,
      entry_ids: entry_ids,
      other_entry_id: other_entry_id,
      all_entry_ids: entry_ids ++ [other_entry_id]
    }
  end

  defp insert_concurrency_fixture(fixture) do
    now = DateTime.utc_now()

    Repo.insert_all("domains", [domain_row(fixture, now)])

    Repo.insert_all("mailboxes", [
      mailbox_row(fixture.mailbox_id, fixture.domain_id, "target", now),
      mailbox_row(fixture.other_mailbox_id, fixture.domain_id, "other", now)
    ])

    Repo.insert_all(
      "inbound_deliveries",
      Enum.map(fixture.delivery_ids, &delivery_row(&1, fixture.domain_id, now))
    )

    target_rows =
      Enum.zip_with(
        fixture.entry_ids,
        Enum.take(fixture.delivery_ids, 6),
        &mailbox_entry_row(&1, fixture.mailbox_id, &2, now)
      )

    other_row =
      mailbox_entry_row(
        fixture.other_entry_id,
        fixture.other_mailbox_id,
        List.last(fixture.delivery_ids),
        now
      )

    Repo.insert_all("mailbox_entries", target_rows ++ [other_row])
  end

  defp domain_row(fixture, now) do
    %{
      id: Ecto.UUID.dump!(fixture.domain_id),
      name: fixture.domain,
      normalized_domain: fixture.domain,
      active: true,
      plus_addressing_enabled: true,
      inserted_at: now,
      updated_at: now
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

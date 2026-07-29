defmodule Manifold.Mail.ProjectorTest do
  use Manifold.DataCase, async: false

  alias Manifold.Mail
  alias Manifold.Mail.InboundSource

  alias Manifold.Mail.Schema.{
    Attachment,
    Folder,
    MailboxEntry,
    Message,
    MessageAddress,
    MessageHeader,
    Thread
  }

  alias Manifold.Repo
  alias Manifold.Storage.{BlobStore, RawStore}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)
    old_blob = Application.fetch_env!(:manifold_storage, :blob_store_dir)

    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))
    Application.put_env(:manifold_storage, :blob_store_dir, Path.join(tmp_dir, "blobs"))

    on_exit(fn ->
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
      Application.put_env(:manifold_storage, :blob_store_dir, old_blob)
    end)

    :ok
  end

  test "projects an archived message, attachment, folders, thread, and mailbox entry idempotently",
       %{tmp_dir: tmp_dir} do
    mailbox_id = mailbox_fixture()

    raw =
      multipart_message(
        "<project-1@example.net>",
        "Projected",
        "This is searchable text",
        "report.txt",
        "attachment content"
      )

    source = source_fixture(tmp_dir, mailbox_id, raw)

    assert {:ok, first} = Mail.project_inbound(source)
    assert {:ok, second} = Mail.project_inbound(source)
    assert first == second
    assert first.state == :parsed

    message = Repo.get!(Message, first.message_id)
    assert message.subject == "Projected"
    assert message.text_body == "This is searchable text"
    assert message.parse_state == "parsed"
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(MessageHeader, :count) >= 5

    assert [%Attachment{} = attachment] = Repo.all(Attachment)
    assert attachment.filename == "report.txt"
    attachment_sha256 = attachment.sha256
    assert {:ok, %{size: 18, sha256: ^attachment_sha256}} = BlobStore.stat(attachment.object_key)

    assert Repo.aggregate(Folder, :count) == 3
    assert Repo.aggregate(Thread, :count) == 1

    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: source.inbound_delivery_id)
    assert entry.message_id == message.id
    assert entry.thread_id
    assert entry.folder_id
    assert entry.read_at == nil
    assert entry.starred_at == nil

    assert {:ok, folders} = Mail.list_folders(mailbox_id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    archive = Enum.find(folders, &(&1.kind == "archive"))
    trash = Enum.find(folders, &(&1.kind == "trash"))
    assert inbox.total_count == 1
    assert inbox.unread_count == 1

    assert {:ok, %{items: [summary]}} =
             Mail.list_conversations(mailbox_id, inbox.id)

    assert summary.subject == "Projected"
    assert summary.unread
    assert summary.starred == false
    assert summary.attachment_count == 1

    assert {:ok, %{items: [_summary]}} = Mail.search(mailbox_id, "searchable")
    assert {:ok, %{items: []}} = Mail.search(mailbox_id, "not-present")

    assert {:ok, conversation} = Mail.get_conversation(mailbox_id, entry.thread_id)
    assert [%{entry_id: entry_id, attachments: [attachment_view]}] = conversation.messages

    assert {:ok, download} = Mail.open_attachment(mailbox_id, attachment_view.id)
    assert IO.binread(download.io, :eof) == "attachment content"
    assert :ok = File.close(download.io)
    refute Map.has_key?(Map.from_struct(download), :object_key)

    assert {:ok, 1} = Mail.mark_read(mailbox_id, [entry_id], true)

    assert {:ok, %{messages: [%{read: true}]}} =
             Mail.get_conversation(mailbox_id, entry.thread_id)

    assert {:ok, 1} = Mail.set_starred(mailbox_id, [entry_id], true)

    assert {:ok, %{messages: [%{starred: true}]}} =
             Mail.get_conversation(mailbox_id, entry.thread_id)

    assert {:ok, 1} = Mail.archive(mailbox_id, [entry_id])
    assert {:ok, %{items: []}} = Mail.list_conversations(mailbox_id, inbox.id)
    assert {:ok, %{items: [_summary]}} = Mail.list_conversations(mailbox_id, archive.id)

    assert {:ok, 1} = Mail.restore(mailbox_id, [entry_id])
    assert {:ok, %{items: [_summary]}} = Mail.list_conversations(mailbox_id, inbox.id)

    assert {:ok, 1} = Mail.trash(mailbox_id, [entry_id])
    assert {:ok, %{items: [_summary]}} = Mail.list_conversations(mailbox_id, trash.id)
    assert {:ok, 1} = Mail.restore(mailbox_id, [entry_id])

    other_mailbox_id = mailbox_fixture()
    assert {:ok, other_folders} = Mail.list_folders(other_mailbox_id)
    other_inbox = Enum.find(other_folders, &(&1.kind == "inbox"))
    assert {:ok, %{items: []}} = Mail.list_conversations(other_mailbox_id, other_inbox.id)

    assert {:error, %{reason: :not_found}} =
             Mail.get_conversation(other_mailbox_id, entry.thread_id)

    assert {:error, %{reason: :not_found}} =
             Mail.open_attachment(other_mailbox_id, attachment_view.id)
  end

  test "failure after blob storage but before projection commit is safe to retry", %{
    tmp_dir: tmp_dir
  } do
    mailbox_id = mailbox_fixture()

    source =
      source_fixture(
        tmp_dir,
        mailbox_id,
        multipart_message(
          "<project-crash@example.net>",
          "Crash",
          "Body",
          "retry.bin",
          "stored before commit"
        )
      )

    assert {:error, %{reason: :after_blob_storage_before_commit}} =
             Mail.project_inbound(source, fail_at: :after_blob_storage_before_commit)

    assert Repo.aggregate(Message, :count) == 0

    blob_files =
      tmp_dir
      |> Path.join("blobs/**/*")
      |> Path.wildcard(match_dot: true)
      |> Enum.filter(&File.regular?/1)

    assert [_blob] = blob_files

    assert {:ok, %{state: :parsed}} = Mail.project_inbound(source)
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(Attachment, :count) == 1
  end

  test "higher projection versions atomically rebuild derived rows in place", %{
    tmp_dir: tmp_dir
  } do
    mailbox_id = mailbox_fixture()

    source =
      source_fixture(
        tmp_dir,
        mailbox_id,
        multipart_message(
          "<versioned@example.net>",
          "Versioned",
          "Versioned body",
          "versioned.txt",
          "versioned attachment"
        )
      )

    assert {:ok, first} =
             Mail.project_inbound(source, parser_version: 1, sanitizer_version: 1)

    first_message = Repo.get!(Message, first.message_id)
    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: source.inbound_delivery_id)
    assert {:ok, 1} = Mail.mark_read(mailbox_id, [entry.id], true)
    assert {:ok, 1} = Mail.set_starred(mailbox_id, [entry.id], true)

    first_message
    |> Message.changeset(%{subject: "stale projection"})
    |> Repo.update!()

    assert {:error, %{reason: :after_blob_storage_before_commit}} =
             Mail.project_inbound(source,
               parser_version: 2,
               sanitizer_version: 1,
               fail_at: :after_blob_storage_before_commit
             )

    unchanged = Repo.get!(Message, first.message_id)
    assert unchanged.parser_version == 1
    assert unchanged.subject == "stale projection"

    assert {:ok, rebuilt} =
             Mail.project_inbound(source, parser_version: 2, sanitizer_version: 1)

    assert rebuilt.message_id == first.message_id

    message = Repo.get!(Message, first.message_id)
    assert message.subject == "Versioned"
    assert message.parser_version == 2
    assert message.sanitizer_version == 1
    assert Repo.aggregate(Message, :count) == 1
    assert Repo.aggregate(Attachment, :count) == 1

    preserved_entry = Repo.get!(MailboxEntry, entry.id)
    assert preserved_entry.read_at
    assert preserved_entry.starred_at
    assert preserved_entry.folder_id == entry.folder_id
    assert preserved_entry.thread_id == entry.thread_id

    assert {:ok, _mixed_upgrade} =
             Mail.project_inbound(source, parser_version: 1, sanitizer_version: 2)

    mixed_upgrade = Repo.get!(Message, first.message_id)
    assert mixed_upgrade.parser_version == 2
    assert mixed_upgrade.sanitizer_version == 2

    assert {:ok, _current} =
             Mail.project_inbound(source, parser_version: 1, sanitizer_version: 1)

    current = Repo.get!(Message, first.message_id)
    assert current.parser_version == 2
    assert current.sanitizer_version == 2
  end

  test "reference headers assign a deterministic per-mailbox thread", %{tmp_dir: tmp_dir} do
    mailbox_id = mailbox_fixture()

    first =
      source_fixture(
        tmp_dir,
        mailbox_id,
        plain_message("<thread-root@example.net>", "Topic", "first")
      )

    second =
      source_fixture(
        tmp_dir,
        mailbox_id,
        plain_message(
          "<thread-reply@example.net>",
          "Re: Topic",
          "second",
          "In-Reply-To: <thread-root@example.net>\r\nReferences: <thread-root@example.net>\r\n"
        )
      )

    assert {:ok, _first} = Mail.project_inbound(first)
    assert {:ok, _second} = Mail.project_inbound(second)

    entries =
      MailboxEntry
      |> where([entry], entry.mailbox_id == ^mailbox_id)
      |> order_by([entry], asc: entry.inserted_at)
      |> Repo.all()

    assert [first_entry, second_entry] = entries
    assert first_entry.thread_id == second_entry.thread_id
    assert Repo.get!(Thread, first_entry.thread_id).message_count == 2
  end

  test "duplicate Message-IDs resolve replies to the oldest matching projection", %{
    tmp_dir: tmp_dir
  } do
    mailbox_id = mailbox_fixture()

    first =
      source_fixture(
        tmp_dir,
        mailbox_id,
        plain_message("<duplicate@example.net>", "First", "first")
      )

    second =
      source_fixture(
        tmp_dir,
        mailbox_id,
        plain_message("<duplicate@example.net>", "Second", "second")
      )

    assert {:ok, _first} = Mail.project_inbound(first)
    Process.sleep(2)
    assert {:ok, _second} = Mail.project_inbound(second)

    reply =
      source_fixture(
        tmp_dir,
        mailbox_id,
        plain_message(
          "<duplicate-reply@example.net>",
          "Re: First",
          "reply",
          "In-Reply-To: <duplicate@example.net>\r\n"
        )
      )

    assert {:ok, _reply} = Mail.project_inbound(reply)

    [first_entry, second_entry, reply_entry] =
      MailboxEntry
      |> where([entry], entry.mailbox_id == ^mailbox_id)
      |> order_by([entry], asc: entry.inserted_at, asc: entry.id)
      |> Repo.all()

    refute first_entry.thread_id == second_entry.thread_id
    assert reply_entry.thread_id == first_entry.thread_id
    assert Repo.get!(Thread, first_entry.thread_id).message_count == 2
    assert Repo.get!(Thread, second_entry.thread_id).message_count == 1
  end

  test "concurrent replies and rebuild retain one thread and an exact message count", %{
    tmp_dir: tmp_dir
  } do
    mailbox_id = mailbox_fixture()

    root =
      source_fixture(
        tmp_dir,
        mailbox_id,
        plain_message("<concurrent-root@example.net>", "Concurrent", "root")
      )

    assert {:ok, _root} = Mail.project_inbound(root)

    replies =
      for index <- 1..2 do
        source_fixture(
          tmp_dir,
          mailbox_id,
          plain_message(
            "<concurrent-reply-#{index}@example.net>",
            "Re: Concurrent",
            "reply #{index}",
            "In-Reply-To: <concurrent-root@example.net>\r\n"
          )
        )
      end

    operations =
      [
        fn -> Mail.project_inbound(root, parser_version: 2, sanitizer_version: 1) end
        | Enum.map(replies, fn reply -> fn -> Mail.project_inbound(reply) end end)
      ]

    assert [ok: {:ok, _rebuild}, ok: {:ok, _first}, ok: {:ok, _second}] =
             Task.async_stream(operations, & &1.(),
               max_concurrency: 3,
               ordered: true,
               timeout: 30_000
             )
             |> Enum.to_list()

    entries =
      MailboxEntry
      |> where([entry], entry.mailbox_id == ^mailbox_id)
      |> Repo.all()

    assert [thread_id] = entries |> Enum.map(& &1.thread_id) |> Enum.uniq()
    assert Repo.get!(Thread, thread_id).message_count == 3

    assert Repo.get_by!(Message, inbound_delivery_id: root.inbound_delivery_id).parser_version ==
             2
  end

  test "large high-cardinality bodies remain projectable and preserve the raw text", %{
    tmp_dir: tmp_dir
  } do
    mailbox_id = mailbox_fixture()
    body = Enum.map_join(1..150_000, " ", &"token#{&1}")

    source =
      source_fixture(
        tmp_dir,
        mailbox_id,
        plain_message("<large-search@example.net>", "Large search", body)
      )

    assert {:ok, %{state: :parsed, message_id: message_id}} = Mail.project_inbound(source)
    assert Repo.get!(Message, message_id).text_body == body
    assert {:ok, %{items: [_summary]}} = Mail.search(mailbox_id, "token100")
  end

  test "sender-controlled NUL bytes are removed before persistence", %{tmp_dir: tmp_dir} do
    mailbox_id = mailbox_fixture()

    source =
      source_fixture(
        tmp_dir,
        mailbox_id,
        plain_message("<nul@example.net>", "NUL" <> <<0>> <> "subject", "body" <> <<0>> <> "text")
      )

    assert {:ok, %{message_id: message_id}} = Mail.project_inbound(source)
    message = Repo.get!(Message, message_id)

    persisted_text =
      [
        message.subject,
        message.sender_name,
        message.sender_address,
        message.text_body,
        message.sanitized_html
      ] ++
        Enum.flat_map(Repo.all(MessageHeader), fn header ->
          [header.original_name, header.normalized_name, header.unfolded_value]
        end)

    refute Enum.any?(persisted_text, &(is_binary(&1) and String.contains?(&1, <<0>>)))
  end

  test "long unfolded subjects remain visible with a bounded thread summary", %{tmp_dir: tmp_dir} do
    mailbox_id = mailbox_fixture()
    first_half = String.duplicate("a", 800)
    second_half = String.duplicate("b", 800)

    raw =
      "From: sender@example.net\r\n" <>
        "To: inbox@mail.test\r\n" <>
        "Subject: #{first_half}\r\n #{second_half}\r\n" <>
        "Content-Type: text/plain; charset=utf-8\r\n\r\n" <>
        "Body\r\n"

    source = source_fixture(tmp_dir, mailbox_id, raw)

    assert {:ok, %{state: :parsed, message_id: message_id}} = Mail.project_inbound(source)

    message = Repo.get!(Message, message_id)
    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: source.inbound_delivery_id)
    thread = Repo.get!(Thread, entry.thread_id)

    assert String.length(message.subject) > 998
    assert String.length(thread.subject_summary) == 998
    assert String.starts_with?(message.subject, first_half)
  end

  test "persists all normalized address kinds", %{tmp_dir: tmp_dir} do
    mailbox_id = mailbox_fixture()

    raw =
      "From: Author <author@example.net>\r\n" <>
        "Sender: Agent <agent@example.net>\r\n" <>
        "Reply-To: Replies <reply@example.net>\r\n" <>
        "To: inbox@mail.test\r\n" <>
        "Cc: Copy <copy@example.net>\r\n" <>
        "Bcc: Hidden <hidden@example.net>\r\n" <>
        "Subject: Address projection\r\n" <>
        "Content-Type: text/plain; charset=utf-8\r\n\r\n" <>
        "Body\r\n"

    source = source_fixture(tmp_dir, mailbox_id, raw)
    assert {:ok, %{message_id: message_id}} = Mail.project_inbound(source)

    addresses =
      MessageAddress
      |> where([address], address.message_id == ^message_id)
      |> order_by([address], asc: address.kind, asc: address.position)
      |> Repo.all()

    assert Enum.map(addresses, &{&1.kind, &1.canonical_address}) == [
             {"bcc", "hidden@example.net"},
             {"cc", "copy@example.net"},
             {"from", "author@example.net"},
             {"reply_to", "reply@example.net"},
             {"sender", "agent@example.net"},
             {"to", "inbox@mail.test"}
           ]
  end

  test "malformed MIME creates a visible fallback projection without losing the raw source",
       %{tmp_dir: tmp_dir} do
    mailbox_id = mailbox_fixture()

    raw =
      "From: sender@example.net\r\n" <>
        "To: inbox@example.test\r\n" <>
        "Subject: Broken\r\n" <>
        "Content-Type: multipart/mixed; boundary=missing\r\n\r\n" <>
        "This body has no MIME boundary.\r\n"

    source = source_fixture(tmp_dir, mailbox_id, raw)

    assert {:ok, %{state: :fallback, message_id: message_id}} = Mail.project_inbound(source)
    assert Repo.get!(Message, message_id).parse_state == "fallback"

    assert Repo.get_by!(MailboxEntry, inbound_delivery_id: source.inbound_delivery_id).message_id ==
             message_id

    assert {:ok, _stat} = RawStore.stat(source.raw_object_key)
  end

  defp mailbox_fixture do
    now = DateTime.utc_now()
    domain_id = Ecto.UUID.generate()
    mailbox_id = Ecto.UUID.generate()
    suffix = System.unique_integer([:positive])
    domain = "mail#{suffix}.test"

    Repo.insert_all("domains", [
      %{
        id: dump_uuid(domain_id),
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
        id: dump_uuid(mailbox_id),
        domain_id: dump_uuid(domain_id),
        local_part: "inbox",
        canonical_local_part: "inbox",
        active: true,
        plus_addressing_enabled: true,
        inserted_at: now,
        updated_at: now
      }
    ])

    mailbox_id
  end

  defp source_fixture(tmp_dir, mailbox_id, raw) do
    now = DateTime.utc_now()
    delivery_id = Ecto.UUID.generate()
    ingest_id = Ecto.UUID.generate()
    sha256 = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    raw_key = RawStore.build_key(mailbox_id, now, delivery_id)
    source_path = Path.join(tmp_dir, delivery_id <> ".eml")
    File.write!(source_path, raw)
    assert {:ok, _stat} = RawStore.put_from_path(raw_key, source_path)

    Repo.insert_all("inbound_deliveries", [
      %{
        id: dump_uuid(delivery_id),
        ingest_id: ingest_id,
        peer_ip: "127.0.0.1",
        envelope_from: "sender@example.net",
        received_at: now,
        raw_size: byte_size(raw),
        raw_sha256: sha256,
        spool_bundle_path: Path.join(tmp_dir, "removed-spool"),
        raw_object_key: raw_key,
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
        original_recipient: "inbox@mail.test",
        quarantined: false
      })
    )

    %InboundSource{
      inbound_delivery_id: delivery_id,
      raw_object_key: raw_key,
      raw_size: byte_size(raw),
      raw_sha256: sha256,
      received_at: now
    }
  end

  defp plain_message(message_id, subject, body, extra_headers \\ "") do
    "From: Sender <sender@example.net>\r\n" <>
      "To: inbox@mail.test\r\n" <>
      "Subject: #{subject}\r\n" <>
      "Message-ID: #{message_id}\r\n" <>
      extra_headers <>
      "Content-Type: text/plain; charset=utf-8\r\n\r\n" <>
      body <>
      "\r\n"
  end

  defp multipart_message(message_id, subject, text, filename, attachment) do
    encoded = Base.encode64(attachment)

    "From: Sender <sender@example.net>\r\n" <>
      "To: inbox@mail.test\r\n" <>
      "Subject: #{subject}\r\n" <>
      "Message-ID: #{message_id}\r\n" <>
      "Content-Type: multipart/mixed; boundary=projection\r\n\r\n" <>
      "--projection\r\n" <>
      "Content-Type: text/plain; charset=utf-8\r\n\r\n" <>
      text <>
      "\r\n--projection\r\n" <>
      "Content-Type: application/octet-stream; name=\"#{filename}\"\r\n" <>
      "Content-Disposition: attachment; filename=\"#{filename}\"\r\n" <>
      "Content-Transfer-Encoding: base64\r\n\r\n" <>
      encoded <>
      "\r\n--projection--\r\n"
  end

  defp dump_uuid(uuid), do: Ecto.UUID.dump!(uuid)
end

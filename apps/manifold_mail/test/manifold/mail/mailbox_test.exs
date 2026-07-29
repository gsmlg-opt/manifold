defmodule Manifold.Mail.MailboxTest do
  use Manifold.DataCase, async: true

  alias Manifold.Mail

  alias Manifold.Mail.Schema.{
    Attachment,
    Folder,
    MailboxEntry,
    Message,
    MessageAddress,
    Thread
  }

  alias Manifold.Repo

  test "paginates distinct conversations without a message-row cap" do
    mailbox_id = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox_id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    now = DateTime.utc_now()

    newest = thread_fixture(mailbox_id, inbox.id, "Newest", now, 41)
    middle = thread_fixture(mailbox_id, inbox.id, "Middle", DateTime.add(now, -60), 1)
    oldest = thread_fixture(mailbox_id, inbox.id, "Oldest", DateTime.add(now, -120), 1)

    assert {:ok, first_page} = Mail.list_conversations(mailbox_id, inbox.id, limit: 2)

    assert [
             %{thread_id: newest_id, message_count: 41},
             %{thread_id: middle_id, message_count: 1}
           ] = first_page.items

    assert newest_id == newest.thread.id
    assert middle_id == middle.thread.id
    assert is_binary(first_page.next_cursor)

    assert {:ok, second_page} =
             Mail.list_conversations(mailbox_id, inbox.id,
               limit: 2,
               after: first_page.next_cursor
             )

    assert [%{thread_id: oldest_id, message_count: 1}] = second_page.items
    assert oldest_id == oldest.thread.id
    assert second_page.next_cursor == nil
  end

  test "conversation detail is folder scoped" do
    mailbox_id = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox_id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    archive = Enum.find(folders, &(&1.kind == "archive"))
    %{thread: thread} = thread_fixture(mailbox_id, inbox.id, "Scoped", DateTime.utc_now(), 1)

    assert {:ok, %{thread_id: thread_id}} =
             Mail.get_conversation(mailbox_id, inbox.id, thread.id)

    assert thread_id == thread.id

    assert {:error, %{reason: :not_found}} =
             Mail.get_conversation(mailbox_id, archive.id, thread.id)
  end

  test "folder summaries, ordering, and cursors exclude messages in other folders" do
    mailbox_id = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox_id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    archive = Enum.find(folders, &(&1.kind == "archive"))
    now = DateTime.utc_now()

    %{thread: split_thread} =
      thread_fixture(mailbox_id, inbox.id, "Split", DateTime.add(now, -120), 2)

    hidden =
      projected_message_fixture(mailbox_id, inbox.id, split_thread.id, "Hidden", now)

    split_thread
    |> Thread.changeset(%{last_message_at: now, message_count: 3})
    |> Repo.update!()

    assert {:ok, 1} = Mail.archive(mailbox_id, [hidden.entry.id])

    %{thread: middle_thread} =
      thread_fixture(mailbox_id, inbox.id, "Middle", DateTime.add(now, -60), 1)

    assert {:ok, first_page} = Mail.list_conversations(mailbox_id, inbox.id, limit: 1)

    assert [
             %{
               thread_id: middle_thread_id,
               message_count: 1,
               last_message_at: middle_last_message_at
             }
           ] = first_page.items

    assert middle_thread_id == middle_thread.id
    assert %DateTime{} = middle_last_message_at
    assert middle_last_message_at == DateTime.add(now, -60)
    assert is_binary(first_page.next_cursor)

    assert {:ok, second_page} =
             Mail.list_conversations(mailbox_id, inbox.id,
               limit: 1,
               after: first_page.next_cursor
             )

    assert [
             %{
               thread_id: split_thread_id,
               message_count: 2,
               last_message_at: split_last_message_at
             }
           ] = second_page.items

    assert split_thread_id == split_thread.id
    assert %DateTime{} = split_last_message_at
    assert split_last_message_at == DateTime.add(now, -120)
    assert second_page.next_cursor == nil

    assert {:ok, archive_page} = Mail.list_conversations(mailbox_id, archive.id)

    assert [
             %{
               thread_id: archived_thread_id,
               message_count: 1,
               last_message_at: archived_last_message_at
             }
           ] = archive_page.items

    assert archived_thread_id == split_thread.id
    assert %DateTime{} = archived_last_message_at
    assert archived_last_message_at == now
  end

  test "quarantined entries cannot expose conversation bodies or attachments" do
    mailbox_id = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox_id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))

    %{thread: thread, entries: [entry], messages: [message]} =
      thread_fixture(mailbox_id, inbox.id, "Quarantined", DateTime.utc_now(), 1)

    attachment =
      %Attachment{}
      |> Attachment.changeset(%{
        message_id: message.id,
        part_path: "1",
        filename: "blocked.txt",
        media_type: "text/plain",
        disposition: "attachment",
        size: 7,
        sha256: String.duplicate("a", 64),
        object_key: "blobs/sha256/aa/#{String.duplicate("a", 64)}"
      })
      |> Repo.insert!()

    entry
    |> MailboxEntry.changeset(%{quarantined: true})
    |> Repo.update!()

    assert {:ok, %{items: []}} = Mail.list_conversations(mailbox_id, inbox.id)
    assert {:error, %{reason: :not_found}} = Mail.get_conversation(mailbox_id, thread.id)

    assert {:error, %{reason: :not_found}} =
             Mail.get_conversation(mailbox_id, inbox.id, thread.id)

    assert {:error, %{reason: :not_found}} = Mail.get_message_body(mailbox_id, message.id)
    assert {:error, %{reason: :not_found}} = Mail.open_attachment(mailbox_id, attachment.id)
  end

  test "delivery quarantine updates every mailbox projection and is idempotent" do
    first_mailbox_id = mailbox_fixture()
    second_mailbox_id = mailbox_fixture()
    assert {:ok, first_folders} = Mail.list_folders(first_mailbox_id)
    inbox = Enum.find(first_folders, &(&1.kind == "inbox"))

    %{entries: [first_entry]} =
      thread_fixture(first_mailbox_id, inbox.id, "Shared delivery", DateTime.utc_now(), 1)

    second_entry =
      %MailboxEntry{}
      |> MailboxEntry.changeset(%{
        mailbox_id: second_mailbox_id,
        inbound_delivery_id: first_entry.inbound_delivery_id,
        original_recipient: "inbox@example.test",
        quarantined: false
      })
      |> Repo.insert!()

    assert {:ok, 2} = Mail.set_delivery_quarantine(first_entry.inbound_delivery_id, true)
    assert Repo.get!(MailboxEntry, first_entry.id).quarantined
    assert Repo.get!(MailboxEntry, second_entry.id).quarantined

    assert {:ok, 0} = Mail.set_delivery_quarantine(first_entry.inbound_delivery_id, true)
    assert {:ok, 2} = Mail.set_delivery_quarantine(first_entry.inbound_delivery_id, false)
    refute Repo.get!(MailboxEntry, first_entry.id).quarantined
    refute Repo.get!(MailboxEntry, second_entry.id).quarantined
  end

  test "normal mailbox mutations cannot bypass quarantine" do
    mailbox_id = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox_id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    archive = Enum.find(folders, &(&1.kind == "archive"))

    %{entries: [entry]} =
      thread_fixture(mailbox_id, inbox.id, "No mutation bypass", DateTime.utc_now(), 1)

    assert {:ok, 1} = Mail.set_delivery_quarantine(entry.inbound_delivery_id, true)
    assert {:ok, 0} = Mail.mark_read(mailbox_id, [entry.id], true)
    assert {:ok, 0} = Mail.set_starred(mailbox_id, [entry.id], true)
    assert {:ok, 0} = Mail.move(mailbox_id, [entry.id], archive.id)

    unchanged = Repo.get!(MailboxEntry, entry.id)
    assert unchanged.quarantined
    assert unchanged.read_at == nil
    assert unchanged.starred_at == nil
    assert unchanged.folder_id == inbox.id
  end

  test "malformed resource identifiers return classified not-found errors" do
    mailbox_id = mailbox_fixture()

    assert {:error, %{reason: :not_found}} =
             Mail.get_conversation(mailbox_id, "not-a-uuid")

    assert {:error, %{reason: :not_found}} =
             Mail.get_message_body(mailbox_id, "not-a-uuid")

    assert {:error, %{reason: :not_found}} =
             Mail.open_attachment(mailbox_id, "not-a-uuid")
  end

  test "reply source exposes ordered addressing and threading through the public context" do
    mailbox_id = mailbox_fixture()
    other_mailbox_id = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox_id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))

    %{messages: [message]} =
      thread_fixture(mailbox_id, inbox.id, "Reply source", ~U[2026-07-29 04:30:00Z], 1)

    message
    |> Message.changeset(%{
      in_reply_to: "<parent@example.net>",
      references: ["<root@example.net>", "<parent@example.net>"]
    })
    |> Repo.update!()

    [
      %{kind: "from", position: 0, display_name: "Sender", address: "sender@example.net"},
      %{kind: "reply_to", position: 0, display_name: "Replies", address: "reply@example.net"},
      %{kind: "to", position: 0, display_name: "Local", address: "inbox@example.test"},
      %{kind: "to", position: 1, display_name: "Team", address: "team@example.net"},
      %{kind: "cc", position: 0, display_name: "Observer", address: "observer@example.net"}
    ]
    |> Enum.each(fn attrs ->
      %MessageAddress{}
      |> MessageAddress.changeset(
        attrs
        |> Map.put(:message_id, message.id)
        |> Map.put(:canonical_address, String.downcase(attrs.address, :ascii))
      )
      |> Repo.insert!()
    end)

    assert {:ok, source} = Mail.get_reply_source(mailbox_id, message.id)
    assert source.message_id == message.id
    assert source.rfc_message_id == message.rfc_message_id
    assert source.references == ["<root@example.net>", "<parent@example.net>"]
    assert source.subject == "Reply source 1"
    assert source.sender == %{display_name: "Sender", address: "sender@example.net"}
    assert source.reply_to == [%{display_name: "Replies", address: "reply@example.net"}]

    assert Enum.map(source.to, & &1.address) == [
             "inbox@example.test",
             "team@example.net"
           ]

    assert Enum.map(source.cc, & &1.address) == ["observer@example.net"]

    assert {:error, %{reason: :not_found}} =
             Mail.get_reply_source(other_mailbox_id, message.id)
  end

  test "restore returns a trashed entry to its custom folder exactly once" do
    mailbox_id = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox_id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    custom = folder_fixture(mailbox_id, "Projects")

    %{entries: [entry]} =
      thread_fixture(mailbox_id, inbox.id, "Restore once", DateTime.utc_now(), 1)

    assert {:ok, 0} = Mail.restore(mailbox_id, [entry.id])
    assert Repo.get!(MailboxEntry, entry.id).folder_id == inbox.id

    assert {:ok, 1} = Mail.move(mailbox_id, [entry.id], custom.id)
    assert {:ok, 1} = Mail.trash(mailbox_id, [entry.id])
    assert {:ok, 1} = Mail.restore(mailbox_id, [entry.id])

    restored = Repo.get!(MailboxEntry, entry.id)
    assert restored.folder_id == custom.id
    assert restored.previous_folder_id == nil

    assert {:ok, 0} = Mail.restore(mailbox_id, [entry.id])
    assert Repo.get!(MailboxEntry, entry.id).folder_id == custom.id
  end

  test "concurrent restore calls apply one locked state transition" do
    mailbox_id = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox_id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    custom = folder_fixture(mailbox_id, "Concurrent")

    %{entries: [entry]} =
      thread_fixture(mailbox_id, inbox.id, "Concurrent restore", DateTime.utc_now(), 1)

    assert {:ok, 1} = Mail.move(mailbox_id, [entry.id], custom.id)
    assert {:ok, 1} = Mail.archive(mailbox_id, [entry.id])

    results =
      1..2
      |> Task.async_stream(
        fn _index -> Mail.restore(mailbox_id, [entry.id]) end,
        max_concurrency: 2,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, result} -> result end)
      |> Enum.sort()

    assert results == [{:ok, 0}, {:ok, 1}]

    restored = Repo.get!(MailboxEntry, entry.id)
    assert restored.folder_id == custom.id
    assert restored.previous_folder_id == nil
  end

  test "restore returns mail trashed from Archive back to Archive" do
    mailbox_id = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox_id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    archive = Enum.find(folders, &(&1.kind == "archive"))

    %{entries: [entry]} =
      thread_fixture(mailbox_id, inbox.id, "Archive restore", DateTime.utc_now(), 1)

    assert {:ok, 1} = Mail.archive(mailbox_id, [entry.id])
    assert {:ok, 1} = Mail.trash(mailbox_id, [entry.id])
    assert {:ok, 1} = Mail.restore(mailbox_id, [entry.id])

    restored = Repo.get!(MailboxEntry, entry.id)
    assert restored.folder_id == archive.id
    assert restored.previous_folder_id == nil

    assert {:ok, 0} = Mail.restore(mailbox_id, [entry.id])
    assert Repo.get!(MailboxEntry, entry.id).folder_id == archive.id
  end

  defp mailbox_fixture do
    now = DateTime.utc_now()
    domain_id = Ecto.UUID.generate()
    mailbox_id = Ecto.UUID.generate()
    suffix = System.unique_integer([:positive])
    domain = "mailbox#{suffix}.test"

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

    mailbox_id
  end

  defp folder_fixture(mailbox_id, name) do
    %Folder{}
    |> Folder.changeset(%{mailbox_id: mailbox_id, kind: "custom", name: name})
    |> Repo.insert!()
  end

  defp thread_fixture(mailbox_id, folder_id, subject, last_message_at, message_count) do
    thread =
      %Thread{}
      |> Thread.changeset(%{
        mailbox_id: mailbox_id,
        subject_summary: subject,
        last_message_at: last_message_at,
        message_count: message_count
      })
      |> Repo.insert!()

    projected =
      Enum.map(1..message_count, fn index ->
        projected_message_fixture(
          mailbox_id,
          folder_id,
          thread.id,
          "#{subject} #{index}",
          DateTime.add(last_message_at, index - message_count, :second)
        )
      end)

    %{
      thread: thread,
      entries: Enum.map(projected, & &1.entry),
      messages: Enum.map(projected, & &1.message)
    }
  end

  defp projected_message_fixture(mailbox_id, folder_id, thread_id, subject, sent_at) do
    now = DateTime.utc_now()
    delivery_id = Ecto.UUID.generate()
    storage_domain_id = mailbox_domain_id(mailbox_id)

    Repo.insert_all("inbound_deliveries", [
      %{
        id: Ecto.UUID.dump!(delivery_id),
        ingest_id: Ecto.UUID.generate(),
        storage_domain_id: Ecto.UUID.dump!(storage_domain_id),
        peer_ip: "127.0.0.1",
        envelope_from: "sender@example.test",
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

    message =
      %Message{}
      |> Message.changeset(%{
        inbound_delivery_id: delivery_id,
        rfc_message_id: "<#{delivery_id}@example.test>",
        subject: subject,
        sender_name: "Sender",
        sender_address: "sender@example.test",
        sent_at: sent_at,
        text_body: "Body for #{subject}",
        sanitized_html: "<p>Body for #{subject}</p>",
        parser_version: 1,
        sanitizer_version: 1,
        parse_state: "parsed"
      })
      |> Repo.insert!()

    entry =
      %MailboxEntry{}
      |> MailboxEntry.changeset(%{
        mailbox_id: mailbox_id,
        inbound_delivery_id: delivery_id,
        message_id: message.id,
        folder_id: folder_id,
        thread_id: thread_id,
        original_recipient: "inbox@example.test",
        quarantined: false
      })
      |> Repo.insert!()

    %{message: message, entry: entry}
  end

  defp mailbox_domain_id(mailbox_id) do
    %{rows: [[domain_id]]} =
      Repo.query!(
        "SELECT domain_id::text FROM mailboxes WHERE id = $1::uuid",
        [Ecto.UUID.dump!(mailbox_id)]
      )

    domain_id
  end
end

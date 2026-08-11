defmodule Manifold.Mail.ExternalStateTest do
  use Manifold.DataCase, async: true

  alias Manifold.Mail
  alias Manifold.Mail.Folders
  alias Manifold.Mail.Schema.{Folder, MailboxEntry, Message, Thread}
  alias Manifold.Repo

  test "returns a temporary classified error while mailbox projection is absent" do
    %{delivery_id: delivery_id, mailbox_id: mailbox_id} = acceptance_fixture()

    assert {:error,
            %Manifold.Core.Error{
              class: :temporary,
              reason: :projection_pending
            }} =
             Mail.apply_external_state(mailbox_id, delivery_id, %{
               folder_kind: "inbox",
               read?: false,
               starred?: false,
               deleted?: false
             })

    assert %MailboxEntry{message_id: nil, folder_id: nil, thread_id: nil} =
             Repo.get_by!(MailboxEntry,
               mailbox_id: mailbox_id,
               inbound_delivery_id: delivery_id
             )
  end

  test "atomically and idempotently applies normalized folder, read, starred, and deleted state" do
    %{delivery_id: delivery_id, entry: entry, mailbox_id: mailbox_id, message: message} =
      projected_fixture()

    assert {:ok, :applied} =
             Mail.apply_external_state(mailbox_id, delivery_id, %{
               folder_kind: "archive",
               read?: true,
               starred?: true,
               deleted?: false
             })

    archived = Repo.get!(MailboxEntry, entry.id)
    archive = Folders.get_system(mailbox_id, "archive")
    assert archived.folder_id == archive.id
    assert %DateTime{} = archived.read_at
    assert %DateTime{} = archived.starred_at
    assert archived.previous_folder_id == nil

    assert {:ok, :applied} =
             Mail.apply_external_state(mailbox_id, delivery_id, %{
               folder_kind: "archive",
               read?: true,
               starred?: true,
               deleted?: false
             })

    unchanged = Repo.get!(MailboxEntry, entry.id)
    assert unchanged.folder_id == archived.folder_id
    assert unchanged.read_at == archived.read_at
    assert unchanged.starred_at == archived.starred_at
    assert unchanged.updated_at == archived.updated_at

    assert {:ok, :applied} =
             Mail.apply_external_state(mailbox_id, delivery_id, %{
               folder_kind: "inbox",
               read?: false,
               starred?: false,
               deleted?: false
             })

    inbox = Folders.get_system(mailbox_id, "inbox")

    assert %MailboxEntry{folder_id: inbox_id, read_at: nil, starred_at: nil} =
             Repo.get!(MailboxEntry, entry.id)

    assert inbox_id == inbox.id

    assert {:ok, :applied} =
             Mail.apply_external_state(mailbox_id, delivery_id, %{
               folder_kind: "trash",
               read?: false,
               starred?: false,
               deleted?: false
             })

    trash = Folders.get_system(mailbox_id, "trash")
    assert Repo.get!(MailboxEntry, entry.id).folder_id == trash.id

    assert {:ok, :applied} =
             Mail.apply_external_state(mailbox_id, delivery_id, %{
               folder_kind: nil,
               read?: true,
               starred?: true,
               deleted?: true
             })

    deleted = Repo.get!(MailboxEntry, entry.id)
    assert deleted.folder_id == trash.id
    assert %DateTime{} = deleted.read_at
    assert %DateTime{} = deleted.starred_at
    assert Repo.get!(Message, message.id).id == message.id

    assert %{rows: [["raw/preserved.eml"]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT raw_object_key FROM inbound_deliveries WHERE id = $1",
               [dump_uuid(delivery_id)]
             )
  end

  test "places provider messages in the Sent system folder" do
    %{delivery_id: delivery_id, mailbox_id: mailbox_id} = projected_fixture()

    assert {:ok, :applied} =
             Mail.apply_external_state(mailbox_id, delivery_id, %{
               folder_kind: "sent",
               read?: true,
               starred?: false,
               deleted?: false
             })

    sent = Repo.get_by!(Folder, mailbox_id: mailbox_id, kind: "sent")
    assert Repo.get_by!(MailboxEntry, inbound_delivery_id: delivery_id).folder_id == sent.id
  end

  defp acceptance_fixture do
    %{delivery_id: delivery_id, mailbox_id: mailbox_id} = base_fixture()

    entry =
      %MailboxEntry{}
      |> MailboxEntry.changeset(%{
        mailbox_id: mailbox_id,
        inbound_delivery_id: delivery_id,
        original_recipient: "inbox@example.test",
        quarantined: false
      })
      |> Repo.insert!()

    %{delivery_id: delivery_id, entry: entry, mailbox_id: mailbox_id}
  end

  defp projected_fixture do
    %{delivery_id: delivery_id, mailbox_id: mailbox_id} = base_fixture()
    {:ok, folders} = Folders.ensure(mailbox_id)
    now = DateTime.utc_now()

    message =
      %Message{}
      |> Message.changeset(%{
        inbound_delivery_id: delivery_id,
        rfc_message_id: "<external-state@example.test>",
        subject: "External state",
        sent_at: now,
        parser_version: 1,
        sanitizer_version: 1,
        parse_state: "parsed"
      })
      |> Repo.insert!()

    thread =
      %Thread{}
      |> Thread.changeset(%{
        mailbox_id: mailbox_id,
        subject_summary: "External state",
        last_message_at: now,
        message_count: 1
      })
      |> Repo.insert!()

    entry =
      %MailboxEntry{}
      |> MailboxEntry.changeset(%{
        mailbox_id: mailbox_id,
        inbound_delivery_id: delivery_id,
        message_id: message.id,
        folder_id: folders.inbox.id,
        thread_id: thread.id,
        original_recipient: "inbox@example.test",
        quarantined: false
      })
      |> Repo.insert!()

    %{
      delivery_id: delivery_id,
      entry: entry,
      mailbox_id: mailbox_id,
      message: message
    }
  end

  defp base_fixture do
    now = DateTime.utc_now()
    domain_id = Ecto.UUID.generate()
    mailbox_id = Ecto.UUID.generate()
    delivery_id = Ecto.UUID.generate()
    suffix = System.unique_integer([:positive])
    domain = "external-state-#{suffix}.test"

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

    Repo.insert_all("inbound_deliveries", [
      %{
        id: dump_uuid(delivery_id),
        ingest_id: Ecto.UUID.generate(),
        source_kind: "provider_import",
        storage_domain_id: dump_uuid(domain_id),
        received_at: now,
        raw_size: 1,
        raw_sha256: String.duplicate("0", 64),
        spool_bundle_path: "/removed",
        raw_object_key: "raw/preserved.eml",
        raw_storage_state: "archived",
        processing_state: "processed",
        inserted_at: now,
        updated_at: now
      }
    ])

    %{delivery_id: delivery_id, mailbox_id: mailbox_id}
  end

  defp dump_uuid(uuid), do: Ecto.UUID.dump!(uuid)
end

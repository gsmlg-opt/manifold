defmodule ManifoldWeb.MailLiveTest do
  use ManifoldWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Mail
  alias Manifold.Mail.Schema.{MailboxEntry, Message, Thread}
  alias Manifold.Repo

  setup do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_transport = Application.get_env(:manifold_connectors, :imap_transport)
    old_fake = Application.get_env(:manifold_connectors, :imap_fake)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :imap_transport, Manifold.Connectors.IMAP.Fake)

    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      messages: [],
      uidvalidity: 1
    })

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:imap_transport, old_transport)
      restore_env(:imap_fake, old_fake)
    end)

    :ok
  end

  test "empty state primary cta goes to add account", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~p"/settings/accounts/new"
    assert html =~ "Add account"
    assert html =~ "Connect an email account"
    assert html =~ ~p"/settings/accounts"
  end

  test "folder header shows total count, unread filter, and sync/compose actions", %{conn: conn} do
    mailbox = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    now = DateTime.utc_now()

    unread = projected_thread(mailbox, inbox.id, "Unread note", now)
    read = projected_thread(mailbox, inbox.id, "Read note", DateTime.add(now, -20))
    assert {:ok, 1} = Mail.mark_read(mailbox.id, [read.entry.id], true)

    assert {:ok, view, html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

    assert html =~ ~s(id="sync-button")
    assert html =~ ~s(id="compose-button")
    assert has_element?(view, ".folder-total-count", "2")
    assert has_element?(view, "#unread-filter")

    html =
      view
      |> element("#unread-filter")
      |> render_click()

    assert html =~ "Unread note"
    refute html =~ "Read note"
    assert_patch(view, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}?unread=1")

    assert {:ok, _view, filtered} =
             live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}?unread=1")

    assert filtered =~ unread.message.subject
    refute filtered =~ read.message.subject
  end

  test "sync queues the enabled receive method for the mailbox", %{conn: conn} do
    mailbox = mailbox_fixture()

    assert {:ok, method} =
             Connectors.create_imap_account(%{
               account_id: mailbox.id,
               email_address: "inbox@#{mailbox.domain.normalized_domain}",
               host: "imap.example.test",
               port: 993,
               tls_mode: "ssl",
               username: "inbox@#{mailbox.domain.normalized_domain}",
               password: "secret"
             })

    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    assert {:ok, view, _html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

    html =
      view
      |> element("#sync-button")
      |> render_click()

    assert html =~ "Synchronization queued."
    assert Enum.any?(Repo.all(Oban.Job), &(&1.args["external_account_id"] == method.id))
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "mailui#{suffix}.test"})

    {:ok, mailbox} =
      Accounts.create_account(domain, %{local_part: "inbox", name: "Local Inbox"})

    %{mailbox | domain: domain}
  end

  defp projected_thread(mailbox, folder_id, subject, sent_at) do
    now = DateTime.utc_now()
    delivery_id = Ecto.UUID.generate()

    Repo.insert_all("inbound_deliveries", [
      %{
        id: Ecto.UUID.dump!(delivery_id),
        ingest_id: Ecto.UUID.generate(),
        storage_domain_id: Ecto.UUID.dump!(mailbox.domain_id),
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

    thread =
      %Thread{}
      |> Thread.changeset(%{
        mailbox_id: mailbox.id,
        subject_summary: subject,
        last_message_at: sent_at,
        message_count: 1
      })
      |> Repo.insert!()

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
        mailbox_id: mailbox.id,
        inbound_delivery_id: delivery_id,
        message_id: message.id,
        folder_id: folder_id,
        thread_id: thread.id,
        original_recipient: "inbox@#{mailbox.domain.normalized_domain}",
        quarantined: false
      })
      |> Repo.insert!()

    %{thread: thread, message: message, entry: entry}
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

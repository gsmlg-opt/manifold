defmodule ManifoldWebTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Ingest
  alias Manifold.Ingest.ExternalSource
  alias Manifold.Ingest.Schema.InboundDelivery
  alias Manifold.Mail
  alias Manifold.Mail.Schema.{Attachment, MailboxEntry, Message, Thread}
  alias Manifold.Repo

  @moduletag :tmp_dir

  defmodule UnavailableBlobStore do
    @behaviour Manifold.Storage.BlobStore

    @impl true
    def put_from_path(_config, _key, _path, _opts), do: {:error, :unavailable}

    @impl true
    def open(_config, _key, _opts), do: {:error, :unavailable}

    @impl true
    def stat(_config, _key, _opts), do: {:error, :unavailable}

    @impl true
    def delete(_config, _key, _opts), do: {:error, :unavailable}
  end

  defmodule InfectedAdapter do
    @behaviour Manifold.Security.MalwareAdapter

    @impl true
    def scan(_config, _input),
      do: {:ok, %{verdict: :infected, signature: "web-test-malware", metadata: %{}}}
  end

  defmodule UnavailableScanner do
    @behaviour Manifold.Security.MalwareAdapter

    @impl true
    def scan(_config, _input) do
      {:error,
       Manifold.Core.Error.new(:temporary, :scanner_unavailable, "scanner is unavailable")}
    end
  end

  setup %{tmp_dir: tmp_dir} do
    old_spool = Application.fetch_env!(:manifold_storage, :spool_dir)
    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)
    old_blob = Application.fetch_env!(:manifold_storage, :blob_store_dir)

    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))
    Application.put_env(:manifold_storage, :blob_store_dir, Path.join(tmp_dir, "blobs"))

    on_exit(fn ->
      Application.put_env(:manifold_storage, :spool_dir, old_spool)
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
      Application.put_env(:manifold_storage, :blob_store_dir, old_blob)
    end)

    :ok
  end

  test "local access can view accounts and delivery lists", %{conn: conn} do
    %{domain: domain} = mailbox_fixture()

    assert {:ok, _view, html} = live(conn, ~p"/settings/accounts")
    assert html =~ "inbox@#{domain.normalized_domain}"

    assert {:ok, _delivery} = delivery_fixture(domain)
    assert {:ok, _view, html} = live(conn, ~p"/deliveries")
    assert html =~ "sender@example.net"
  end

  test "delivery details are loaded through context projection", %{conn: conn} do
    %{domain: domain} = mailbox_fixture()
    {:ok, delivery} = delivery_fixture(domain)

    assert {:ok, _view, html} = live(conn, ~p"/deliveries/#{delivery.id}")
    assert html =~ "sender@example.net"
    assert html =~ "inbox@#{domain.normalized_domain}"
    assert html =~ delivery.raw_sha256
    assert html =~ "Pending security evaluation"
  end

  test "provider delivery details distinguish absent SMTP facts", %{conn: conn} do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()

    source = %ExternalSource{
      provider: "gmail",
      account_id: Ecto.UUID.generate(),
      external_message_id: "provider-web-message",
      mailbox_id: mailbox.id,
      storage_domain_id: domain.id,
      recipient_address: "person@gmail.example",
      received_at: DateTime.utc_now(),
      ingest_id: "provider-web-#{System.unique_integer([:positive])}"
    }

    assert {:ok, receipt} =
             Ingest.import_external("Subject: provider\r\n\r\nBody\r\n", source)

    assert {:ok, _view, html} = live(conn, ~p"/deliveries/#{receipt.inbound_delivery_id}")
    assert html =~ "External provider import"
    assert html =~ "Not applicable"
    assert html =~ "No SMTP envelope recipients were observed"
    assert html =~ "inbox"
  end

  test "delivery operations show assessment evidence and release quarantine", %{conn: conn} do
    %{domain: domain} = mailbox_fixture()
    {:ok, delivery} = delivery_fixture(domain)
    assert :ok = Ingest.archive_delivery(delivery.id)
    assert :ok = Ingest.evaluate_security(delivery.id, malware_adapter: InfectedAdapter)

    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: delivery.id)
    assert entry.quarantined

    assert {:ok, view, html} = live(conn, ~p"/deliveries/#{delivery.id}")
    assert html =~ "web-test-malware"
    assert html =~ "quarantine"

    html =
      view
      |> element("#release-quarantine")
      |> render_click()

    assert html =~ "released"
    refute Repo.get!(MailboxEntry, entry.id).quarantined
  end

  test "delivery operations expose classified security failures without exposing mail", %{
    conn: conn
  } do
    %{domain: domain} = mailbox_fixture()
    {:ok, delivery} = delivery_fixture(domain)
    assert :ok = Ingest.archive_delivery(delivery.id)

    assert {:error, %{reason: :scanner_unavailable}} =
             Ingest.evaluate_security(delivery.id, malware_adapter: UnavailableScanner)

    assert Repo.get_by!(MailboxEntry, inbound_delivery_id: delivery.id).quarantined

    assert {:ok, _view, html} = live(conn, ~p"/deliveries")
    assert html =~ "Failed"

    assert {:ok, _view, html} = live(conn, ~p"/deliveries/#{delivery.id}")
    assert html =~ "scanner_unavailable"
    assert html =~ "scanner is unavailable"
    refute html =~ "Release quarantine"
  end

  test "open delivery views refresh after committed ingest lifecycle events", %{conn: conn} do
    %{domain: domain} = mailbox_fixture()
    assert {:ok, index_view, html} = live(conn, ~p"/deliveries")
    refute html =~ "sender@example.net"

    {:ok, delivery} = delivery_fixture(domain)
    assert render(index_view) =~ "sender@example.net"

    assert {:ok, detail_view, html} = live(conn, ~p"/deliveries/#{delivery.id}")
    assert html =~ "spooled"

    assert :ok = Ingest.archive_delivery(delivery.id)
    assert render(detail_view) =~ "archived"
  end

  test "raw paths and object-store keys are not exposed as direct public URLs", %{conn: conn} do
    %{domain: domain} = mailbox_fixture()
    {:ok, delivery} = delivery_fixture(domain)

    assert {:error, _} =
             Ingest.archive_delivery(delivery.id, fail_at: :after_archived_state_before_cleanup)

    archived = Repo.get!(Manifold.Ingest.Schema.InboundDelivery, delivery.id)

    assert {:ok, _view, html} = live(conn, ~p"/deliveries/#{delivery.id}")

    refute html =~ archived.spool_bundle_path
    refute html =~ archived.raw_object_key
  end

  test "local inbox renders projected conversations and mailbox actions", %{conn: conn} do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    projected = projected_delivery_fixture(domain)

    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))

    assert {:ok, _view, html} =
             live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

    assert html =~ "Inbox"
    assert html =~ "A projected message"
    assert html =~ "Sender"

    assert {:ok, view, html} =
             live(
               conn,
               ~p"/mail/#{mailbox.id}/folders/#{inbox.id}/threads/#{projected.entry.thread_id}"
             )

    assert html =~ "/messages/#{projected.message.id}/body"
    assert html =~ "report.txt"
    assert html =~ "sandbox=\"allow-popups\""

    view
    |> element("button[phx-click=star]")
    |> render_click()

    assert Repo.get!(MailboxEntry, projected.entry.id).starred_at

    view
    |> element("button[phx-click=mark-read]")
    |> render_click()

    assert Repo.get!(MailboxEntry, projected.entry.id).read_at

    view
    |> element("button[phx-click=archive]")
    |> render_click()

    assert Repo.get!(MailboxEntry, projected.entry.id).folder_id != inbox.id
    refute render(view) =~ "A projected message"
  end

  test "mail search uses the mailbox-scoped public context", %{conn: conn} do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    _projected = projected_delivery_fixture(domain)
    {:ok, folders} = Mail.list_folders(mailbox.id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))

    assert {:ok, view, _html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")

    assert view
           |> form("form[phx-submit=search]", %{query: "projected"})
           |> render_submit() =~ "A projected message"

    refute view
           |> form("form[phx-submit=search]", %{query: "not-present"})
           |> render_submit() =~ "A projected message"
  end

  test "conversation pagination exposes every page in the LiveView", %{conn: conn} do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    mailbox_page_fixtures(domain.id, mailbox.id, inbox.id, 51)

    assert {:ok, view, html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")
    assert html =~ "Paged message 1"
    assert html =~ "Next page"
    refute html =~ "Paged message 51"

    html =
      view
      |> element(".pagination-next")
      |> render_click()

    assert html =~ "Paged message 51"
    assert html =~ "First page"
  end

  test "conversation route is scoped to its selected folder", %{conn: conn} do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    projected = projected_delivery_fixture(domain)
    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    trash = Enum.find(folders, &(&1.kind == "trash"))

    assert {:error, {_redirect_kind, %{to: "/"}}} =
             live(
               conn,
               ~p"/mail/#{mailbox.id}/folders/#{trash.id}/threads/#{projected.entry.thread_id}"
             )
  end

  test "open mailbox refreshes after a committed projection", %{conn: conn} do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    assert {:ok, view, html} = live(conn, ~p"/mail/#{mailbox.id}/folders/#{inbox.id}")
    refute html =~ "A projected message"

    _projected = projected_delivery_fixture(domain)

    assert render(view) =~ "A projected message"
  end

  test "message bodies and attachments are safe mailbox-scoped resources", %{conn: conn} do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    projected = projected_delivery_fixture(domain)
    %{mailbox: other_mailbox} = mailbox_fixture()

    body_conn =
      get(conn, ~p"/mailboxes/#{mailbox.id}/messages/#{projected.message.id}/body")

    body = html_response(body_conn, 200)
    assert body =~ "Safe HTML body"
    assert body =~ "https://example.net"
    refute body =~ "<script"
    refute body =~ "tracker.example"

    assert Plug.Conn.get_resp_header(body_conn, "content-security-policy") == [
             "default-src 'none'; img-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'"
           ]

    attachment_conn =
      get(
        recycle(conn),
        ~p"/mailboxes/#{mailbox.id}/attachments/#{projected.attachment.id}"
      )

    assert response(attachment_conn, 200) == "attachment"

    assert Plug.Conn.get_resp_header(attachment_conn, "content-type") == [
             "application/octet-stream"
           ]

    assert Plug.Conn.get_resp_header(attachment_conn, "x-content-type-options") == ["nosniff"]

    assert Plug.Conn.get_resp_header(attachment_conn, "content-disposition") == [
             "attachment; filename=\"attachment\"; filename*=UTF-8''report.txt"
           ]

    refute response(attachment_conn, 200) =~ projected.attachment.object_key

    assert get(
             recycle(conn),
             ~p"/mailboxes/#{other_mailbox.id}/messages/#{projected.message.id}/body"
           )
           |> response(404)

    assert get(
             recycle(conn),
             ~p"/mailboxes/#{other_mailbox.id}/attachments/#{projected.attachment.id}"
           )
           |> response(404)
  end

  test "quarantined mail cannot be opened by known resource identifiers", %{conn: conn} do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    projected = projected_delivery_fixture(domain)
    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))

    projected.entry
    |> MailboxEntry.changeset(%{quarantined: true})
    |> Repo.update!()

    assert get(
             conn,
             ~p"/mailboxes/#{mailbox.id}/messages/#{projected.message.id}/body"
           )
           |> response(404)

    assert get(
             recycle(conn),
             ~p"/mailboxes/#{mailbox.id}/attachments/#{projected.attachment.id}"
           )
           |> response(404)

    assert {:error, {_redirect_kind, %{to: "/"}}} =
             live(
               recycle(conn),
               ~p"/mail/#{mailbox.id}/folders/#{inbox.id}/threads/#{projected.entry.thread_id}"
             )
  end

  test "malformed mail resource identifiers return not found", %{conn: conn} do
    %{mailbox: mailbox} = mailbox_fixture()

    assert get(conn, "/mailboxes/#{mailbox.id}/messages/not-a-uuid/body")
           |> response(404)

    assert get(recycle(conn), "/mailboxes/#{mailbox.id}/attachments/not-a-uuid")
           |> response(404)
  end

  test "temporary attachment storage failures return service unavailable", %{conn: conn} do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    projected = projected_delivery_fixture(domain)
    old_backend = Application.fetch_env!(:manifold_storage, :blob_store_backend)
    Application.put_env(:manifold_storage, :blob_store_backend, UnavailableBlobStore)

    on_exit(fn ->
      Application.put_env(:manifold_storage, :blob_store_backend, old_backend)
    end)

    assert get(
             conn,
             ~p"/mailboxes/#{mailbox.id}/attachments/#{projected.attachment.id}"
           )
           |> response(503)
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "web#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})
    %{domain: domain, mailbox: mailbox}
  end

  defp delivery_fixture(domain, raw \\ "Subject: web\r\n\r\nBody\r\n") do
    {:ok, route} = Accounts.resolve_recipient("inbox@#{domain.normalized_domain}")

    Ingest.accept_transport(
      raw,
      %{
        peer_ip: "127.0.0.1",
        helo: "client.example",
        envelope_from: "sender@example.net",
        original_recipients: [route.original_recipient],
        received_at: DateTime.utc_now()
      },
      [route]
    )
  end

  defp projected_delivery_fixture(domain) do
    raw =
      """
      From: Sender <sender@example.net>
      To: inbox@#{domain.normalized_domain}
      Subject: A projected message
      Message-ID: <web-projection-#{System.unique_integer([:positive])}@example.net>
      Content-Type: multipart/mixed; boundary=outer

      --outer
      Content-Type: text/html; charset=utf-8

      <p>Safe HTML body <a href="https://example.net">link</a></p>
      <script>alert("unsafe")</script>
      <img src="https://tracker.example/pixel">
      --outer
      Content-Type: text/plain; name=report.txt
      Content-Disposition: attachment; filename=report.txt
      Content-Transfer-Encoding: base64

      YXR0YWNobWVudA==
      --outer--
      """
      |> String.trim()
      |> String.replace("\n", "\r\n")
      |> Kernel.<>("\r\n")

    assert {:ok, delivery} = delivery_fixture(domain, raw)
    assert :ok = Ingest.archive_delivery(delivery.id)
    assert :ok = Ingest.evaluate_security(delivery.id)
    assert :ok = Ingest.project_delivery(delivery.id)

    message = Repo.get_by!(Message, inbound_delivery_id: delivery.id)

    %{
      delivery: delivery,
      message: message,
      entry: Repo.get_by!(MailboxEntry, inbound_delivery_id: delivery.id),
      attachment: Repo.get_by!(Attachment, message_id: message.id)
    }
  end

  defp mailbox_page_fixtures(domain_id, mailbox_id, folder_id, count) do
    now = DateTime.utc_now()

    fixtures =
      Enum.map(1..count, fn index ->
        delivery_id = Ecto.UUID.generate()
        message_id = Ecto.UUID.generate()
        thread_id = Ecto.UUID.generate()
        entry_id = Ecto.UUID.generate()
        timestamp = DateTime.add(now, -index, :second)

        %{
          delivery: %{
            id: delivery_id,
            ingest_id: Ecto.UUID.generate(),
            peer_ip: "127.0.0.1",
            envelope_from: "sender@example.test",
            received_at: timestamp,
            raw_size: 1,
            raw_sha256: String.duplicate("0", 64),
            spool_bundle_path: "/removed",
            raw_storage_state: "archived",
            processing_state: "processed",
            storage_domain_id: domain_id,
            inserted_at: timestamp,
            updated_at: timestamp
          },
          message: %{
            id: message_id,
            inbound_delivery_id: delivery_id,
            rfc_message_id: "<page-#{index}@example.test>",
            references: [],
            subject: "Paged message #{index}",
            sender_name: "Sender #{index}",
            sender_address: "sender#{index}@example.test",
            sent_at: timestamp,
            text_body: "Page #{index}",
            parser_version: 1,
            sanitizer_version: 1,
            parse_state: "parsed",
            inserted_at: timestamp,
            updated_at: timestamp
          },
          thread: %{
            id: thread_id,
            mailbox_id: mailbox_id,
            subject_summary: "Paged message #{index}",
            last_message_at: timestamp,
            message_count: 1,
            inserted_at: timestamp,
            updated_at: timestamp
          },
          entry: %{
            id: entry_id,
            mailbox_id: mailbox_id,
            inbound_delivery_id: delivery_id,
            message_id: message_id,
            folder_id: folder_id,
            thread_id: thread_id,
            original_recipient: "inbox@example.test",
            quarantined: false,
            inserted_at: timestamp,
            updated_at: timestamp
          }
        }
      end)

    Repo.insert_all(InboundDelivery, Enum.map(fixtures, & &1.delivery))
    Repo.insert_all(Message, Enum.map(fixtures, & &1.message))
    Repo.insert_all(Thread, Enum.map(fixtures, & &1.thread))
    Repo.insert_all(MailboxEntry, Enum.map(fixtures, & &1.entry))
  end
end

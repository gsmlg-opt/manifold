defmodule ManifoldAPI.RestTest do
  use ManifoldAPI.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Ingest
  alias Manifold.Mail.Schema.{Attachment, MailboxEntry, Message}
  alias Manifold.Repo

  @moduletag :tmp_dir

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

  test "health returns ok", %{conn: conn} do
    conn = get(conn, "/api/v1/health")
    assert %{"status" => "ok", "service" => "manifold_api"} = json_response(conn, 200)
  end

  test "well-known discovery document", %{conn: conn} do
    base = ManifoldAPI.Endpoint.url()

    assert %{
             "product" => "manifold",
             "version" => "0.1.0",
             "auth" => "deployment_boundary",
             "api" => %{
               "rest" => %{
                 "base" => rest_base,
                 "health" => health
               },
               "graphql" => %{"http" => graphql_http}
             },
             "capabilities" => capabilities
           } = json_response(get(conn, "/.well-known/manifold"), 200)

    assert rest_base == base <> "/api/v1"
    assert health == base <> "/api/v1/health"
    assert graphql_http == base <> "/api/graphql"
    assert "mail.read" in capabilities
    assert "mail.search" in capabilities
    assert "attachments.download" in capabilities
  end

  test "mail read and search resources", %{conn: conn} do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    projected = projected_delivery_fixture(domain)

    assert %{"data" => mailboxes} = json_response(get(conn, "/api/v1/mailboxes"), 200)
    assert Enum.any?(mailboxes, &(&1["id"] == mailbox.id))
    assert Enum.any?(mailboxes, &(&1["address"] == "inbox@#{domain.normalized_domain}"))

    assert %{"data" => folders} =
             json_response(get(conn, "/api/v1/mailboxes/#{mailbox.id}/folders"), 200)

    inbox = Enum.find(folders, &(&1["kind"] == "inbox"))
    assert inbox
    assert inbox["total_count"] >= 1

    assert %{"items" => [summary | _], "next_cursor" => _} =
             json_response(
               get(
                 conn,
                 "/api/v1/mailboxes/#{mailbox.id}/folders/#{inbox["id"]}/conversations"
               ),
               200
             )

    assert summary["thread_id"]
    assert summary["subject"] == "A projected message"
    assert summary["attachment_count"] >= 1

    assert %{"items" => search_items} =
             json_response(
               get(conn, "/api/v1/mailboxes/#{mailbox.id}/search?q=projected"),
               200
             )

    assert Enum.any?(search_items, &(&1["thread_id"] == summary["thread_id"]))

    entry = Repo.get!(MailboxEntry, hd(summary["entry_ids"]))

    assert %{"thread_id" => thread_id, "messages" => [message | _]} =
             json_response(
               get(
                 conn,
                 "/api/v1/mailboxes/#{mailbox.id}/conversations/#{entry.thread_id}"
               ),
               200
             )

    assert thread_id == entry.thread_id
    assert message["id"] == projected.message.id
    assert message["has_html"] == true
    assert [%{"url" => url, "filename" => "report.txt"} | _] = message["attachments"]
    assert url == "/api/v1/mailboxes/#{mailbox.id}/attachments/#{projected.attachment.id}"

    assert %{"text_body" => _, "html_body" => html, "has_html" => true} =
             json_response(
               get(
                 conn,
                 "/api/v1/mailboxes/#{mailbox.id}/messages/#{projected.message.id}/body"
               ),
               200
             )

    assert html =~ "Safe HTML body"
    refute html =~ "<script>"

    conn =
      get(
        recycle(conn),
        "/api/v1/mailboxes/#{mailbox.id}/attachments/#{projected.attachment.id}"
      )

    assert response(conn, 200) == "attachment"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"attachment\"; filename*=UTF-8''report.txt"
           ]

    assert %{"error" => %{"reason" => "not_found", "class" => "permanent"}} =
             json_response(
               get(
                 recycle(conn),
                 "/api/v1/mailboxes/#{mailbox.id}/conversations/#{Ecto.UUID.generate()}"
               ),
               404
             )
  end

  test "unknown conversation returns structured not found", %{conn: conn} do
    %{mailbox: mailbox} = mailbox_fixture()

    assert %{"error" => %{"reason" => "not_found", "class" => "permanent", "message" => _}} =
             json_response(
               get(
                 conn,
                 "/api/v1/mailboxes/#{mailbox.id}/conversations/#{Ecto.UUID.generate()}"
               ),
               404
             )
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "api#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_mailbox(domain, %{local_part: "inbox"})
    %{domain: domain, mailbox: mailbox}
  end

  defp delivery_fixture(domain, raw) do
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
      Message-ID: <api-projection-#{System.unique_integer([:positive])}@example.net>
      Content-Type: multipart/mixed; boundary=outer

      --outer
      Content-Type: text/html; charset=utf-8

      <p>Safe HTML body <a href="https://example.net">link</a></p>
      <script>alert("unsafe")</script>
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
end

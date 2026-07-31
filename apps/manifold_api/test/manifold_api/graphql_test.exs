defmodule ManifoldAPI.GraphQLTest do
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

  test "graphql queries mirror rest mail capabilities", %{conn: conn} do
    %{domain: domain, mailbox: mailbox} = mailbox_fixture()
    projected = projected_delivery_fixture(domain)

    assert %{"data" => %{"health" => %{"status" => "ok", "service" => "manifold_api"}}} =
             graphql!(conn, "{ health { status service } }")

    assert %{"data" => %{"mailboxes" => mailboxes}} =
             graphql!(conn, "{ mailboxes { id address } }")

    assert Enum.any?(mailboxes, &(&1["id"] == mailbox.id))

    assert %{"data" => %{"folders" => folders}} =
             graphql!(conn, """
             {
               folders(mailboxId: "#{mailbox.id}") {
                 id
                 kind
                 totalCount
               }
             }
             """)

    inbox = Enum.find(folders, &(&1["kind"] == "inbox"))
    assert inbox

    assert %{"data" => %{"conversations" => %{"items" => [summary | _]}}} =
             graphql!(conn, """
             {
               conversations(mailboxId: "#{mailbox.id}", folderId: "#{inbox["id"]}") {
                 items {
                   threadId
                   subject
                   attachmentCount
                   entryIds
                 }
                 nextCursor
               }
             }
             """)

    assert summary["subject"] == "A projected message"
    assert summary["attachmentCount"] >= 1

    assert %{"data" => %{"search" => %{"items" => search_items}}} =
             graphql!(conn, """
             {
               search(mailboxId: "#{mailbox.id}", q: "projected") {
                 items { threadId }
               }
             }
             """)

    assert Enum.any?(search_items, &(&1["threadId"] == summary["threadId"]))

    assert %{
             "data" => %{
               "conversation" => %{
                 "threadId" => thread_id,
                 "messages" => [message | _]
               }
             }
           } =
             graphql!(conn, """
             {
               conversation(mailboxId: "#{mailbox.id}", threadId: "#{summary["threadId"]}") {
                 threadId
                 messages {
                   id
                   hasHtml
                   attachments { id filename url }
                 }
               }
             }
             """)

    assert thread_id == summary["threadId"]
    assert message["id"] == projected.message.id
    assert message["hasHtml"] == true

    assert [%{"filename" => "report.txt", "url" => url} | _] = message["attachments"]
    assert url == "/api/v1/mailboxes/#{mailbox.id}/attachments/#{projected.attachment.id}"

    assert %{
             "data" => %{
               "messageBody" => %{"hasHtml" => true, "htmlBody" => html}
             }
           } =
             graphql!(conn, """
             {
               messageBody(mailboxId: "#{mailbox.id}", messageId: "#{projected.message.id}") {
                 textBody
                 htmlBody
                 hasHtml
               }
             }
             """)

    assert html =~ "Safe HTML body"
  end

  test "graphql returns structured errors for missing conversation", %{conn: conn} do
    %{mailbox: mailbox} = mailbox_fixture()

    assert %{
             "data" => %{"conversation" => nil},
             "errors" => [%{"message" => message, "extensions" => %{"reason" => "not_found"}}]
           } =
             graphql!(conn, """
             {
               conversation(mailboxId: "#{mailbox.id}", threadId: "#{Ecto.UUID.generate()}") {
                 threadId
               }
             }
             """)

    assert message =~ "not found"
  end

  defp graphql!(conn, query) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/graphql", Jason.encode!(%{query: query}))
    |> json_response(200)
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "gql#{suffix}.test"})
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
      Message-ID: <gql-projection-#{System.unique_integer([:positive])}@example.net>
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

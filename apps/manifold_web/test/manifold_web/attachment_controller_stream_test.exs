defmodule ManifoldWeb.AttachmentControllerStreamTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts
  alias Manifold.Ingest
  alias Manifold.Mail.Schema.{Attachment, Message}
  alias Manifold.Repo

  @moduletag :tmp_dir

  defmodule InjectedBlobStore do
    @behaviour Manifold.Storage.BlobStore

    @impl true
    def open(_config, _key, _opts) do
      %{owner: owner, replies: replies} =
        Application.fetch_env!(:manifold_web, :attachment_stream_test)

      io = spawn(fn -> io_loop(owner, replies) end)
      send(owner, {:attachment_io_opened, io})
      {:ok, io}
    end

    @impl true
    def put_from_path(_config, _key, _path, _opts), do: {:error, :unsupported}

    @impl true
    def stat(_config, _key, _opts), do: {:error, :unsupported}

    @impl true
    def delete(_config, _key, _opts), do: {:error, :unsupported}

    defp io_loop(owner, replies) do
      receive do
        {:io_request, from, reply_as, {:get_chars, _encoding, _prompt, _count}} ->
          [reply | remaining] = replies
          send(from, {:io_reply, reply_as, reply})
          io_loop(owner, remaining)

        {:file_request, from, reply_as, :close} ->
          send(from, {:file_reply, reply_as, :ok})
          send(owner, {:attachment_io_closed, self()})
      end
    end
  end

  setup %{tmp_dir: tmp_dir} do
    old_backend = Application.fetch_env!(:manifold_storage, :blob_store_backend)
    old_spool = Application.fetch_env!(:manifold_storage, :spool_dir)
    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)
    old_blob = Application.fetch_env!(:manifold_storage, :blob_store_dir)

    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))
    Application.put_env(:manifold_storage, :blob_store_dir, Path.join(tmp_dir, "blobs"))

    on_exit(fn ->
      Application.put_env(:manifold_storage, :blob_store_backend, old_backend)
      Application.put_env(:manifold_storage, :spool_dir, old_spool)
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
      Application.put_env(:manifold_storage, :blob_store_dir, old_blob)
      Application.delete_env(:manifold_web, :attachment_stream_test)
    end)

    %{mailbox: mailbox, attachment: attachment} = attachment_fixture()

    Application.put_env(
      :manifold_storage,
      :blob_store_backend,
      InjectedBlobStore
    )

    {:ok, mailbox: mailbox, attachment: attachment}
  end

  test "streams a complete attachment with safe chunked response headers", %{
    conn: conn,
    mailbox: mailbox,
    attachment: attachment
  } do
    configure_stream(["attachment", :eof])

    conn =
      get(
        conn,
        ~p"/mailboxes/#{mailbox.id}/attachments/#{attachment.id}"
      )

    assert response(conn, 200) == "attachment"
    assert Plug.Conn.get_resp_header(conn, "content-length") == []
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, no-store"]

    assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"attachment\"; filename*=UTF-8''report.txt"
           ]

    assert_receive {:attachment_io_opened, io}
    assert_receive {:attachment_io_closed, ^io}
    refute Process.alive?(io)
  end

  test "raises and closes the IO device after a mid-stream read failure", %{
    conn: conn,
    mailbox: mailbox,
    attachment: attachment
  } do
    configure_stream(["partial", {:error, :eio}])

    assert_raise File.Error, ~r/read attachment stream.*I\/O error/, fn ->
      get(
        conn,
        ~p"/mailboxes/#{mailbox.id}/attachments/#{attachment.id}"
      )
    end

    assert_receive {:attachment_io_opened, io}
    assert_receive {:attachment_io_closed, ^io}
    refute Process.alive?(io)
  end

  defp configure_stream(replies) do
    Application.put_env(
      :manifold_web,
      :attachment_stream_test,
      %{owner: self(), replies: replies}
    )
  end

  defp attachment_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "attachment#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})

    raw =
      """
      From: Sender <sender@example.net>
      To: inbox@#{domain.normalized_domain}
      Subject: Attachment stream
      Message-ID: <attachment-stream-#{suffix}@example.net>
      Content-Type: multipart/mixed; boundary=outer

      --outer
      Content-Type: text/plain; charset=utf-8

      Body
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

    {:ok, route} = Accounts.resolve_recipient("inbox@#{domain.normalized_domain}")

    assert {:ok, delivery} =
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

    assert :ok = Ingest.archive_delivery(delivery.id)
    assert :ok = Ingest.evaluate_security(delivery.id)
    assert :ok = Ingest.project_delivery(delivery.id)

    message = Repo.get_by!(Message, inbound_delivery_id: delivery.id)

    %{
      mailbox: mailbox,
      attachment: Repo.get_by!(Attachment, message_id: message.id)
    }
  end
end

Code.require_file("../../../../test/support/http_wire.exs", __DIR__)

defmodule ManifoldWeb.AttachmentWireTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.HTTPWire, as: Wire
  alias Manifold.Ingest
  alias Manifold.Mail.Schema.{Attachment, Message}
  alias Manifold.Repo

  @moduletag :tmp_dir

  defmodule BlobStore do
    @behaviour Manifold.Storage.BlobStore

    @impl true
    def open(_config, _key, _opts) do
      %{owner: owner, mode: mode} = Application.fetch_env!(:manifold_web, :attachment_wire_test)

      io =
        spawn(fn ->
          Process.monitor(owner)
          read_loop(owner, mode, 0)
        end)

      send(owner, {:wire_io_opened, io})
      {:ok, io}
    end

    @impl true
    def put_from_path(_config, _key, _path, _opts), do: {:error, :unsupported}
    @impl true
    def stat(_config, _key, _opts), do: {:error, :unsupported}
    @impl true
    def delete(_config, _key, _opts), do: {:error, :unsupported}

    defp read_loop(owner, mode, count) do
      receive do
        {:io_request, from, ref, {:get_chars, _encoding, _prompt, _size}} ->
          reply =
            case {mode, count} do
              {:complete, 0} ->
                "wire attachment"

              {:complete, _} ->
                :eof

              {:disconnect, 0} ->
                String.duplicate("x", 64 * 1024)

              {:disconnect, 1} ->
                send(owner, {:wire_io_waiting, self()})

                receive do
                  :client_closed -> String.duplicate("x", 64 * 1024)
                  {:DOWN, _ref, :process, ^owner, _reason} -> exit(:normal)
                end

              {:disconnect, _} ->
                String.duplicate("x", 64 * 1024)
            end

          send(from, {:io_reply, ref, reply})
          read_loop(owner, mode, count + 1)

        {:file_request, from, ref, :close} ->
          send(owner, {:wire_io_closed, self()})
          send(from, {:file_reply, ref, :ok})

        {:DOWN, _ref, :process, ^owner, _reason} ->
          :ok
      end
    end
  end

  setup %{tmp_dir: tmp_dir} do
    keys = [:blob_store_backend, :spool_dir, :raw_store_dir, :blob_store_dir]
    old = Map.new(keys, &{&1, Application.fetch_env!(:manifold_storage, &1)})
    old_stream = Application.get_env(:manifold_web, :attachment_wire_test)

    for {key, path} <- [spool_dir: "spool", raw_store_dir: "raw", blob_store_dir: "blobs"] do
      Application.put_env(:manifold_storage, key, Path.join(tmp_dir, path))
    end

    on_exit(fn ->
      for {key, value} <- old, do: Application.put_env(:manifold_storage, key, value)

      if old_stream,
        do: Application.put_env(:manifold_web, :attachment_wire_test, old_stream),
        else: Application.delete_env(:manifold_web, :attachment_wire_test)
    end)

    fixture = attachment_fixture()
    Application.put_env(:manifold_storage, :blob_store_backend, BlobStore)
    Map.put(fixture, :port, Wire.start_endpoint(ManifoldWeb.Endpoint, :manifold_web))
  end

  test "transfers attachment bytes with chunked framing and closes the source IO", context do
    configure_stream(:complete)
    response = Wire.request(context.port, "GET", attachment_path(context))
    assert response.status == 200
    assert Wire.header(response.headers, "transfer-encoding") == "chunked"
    assert Wire.header(response.headers, "content-length") == nil
    assert Wire.header(response.headers, "content-type") == "application/octet-stream"
    assert Wire.header(response.headers, "x-content-type-options") == "nosniff"
    assert Wire.header(response.headers, "cache-control") == "private, no-store"
    assert response.body == "wire attachment"
    assert_receive {:wire_io_opened, io}, 5_000
    ref = Process.monitor(io)
    assert_receive {:wire_io_closed, ^io}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^io, _reason}, 5_000
  end

  test "closes attachment IO when the TCP client disconnects during transfer", context do
    configure_stream(:disconnect)
    socket = Wire.connect(context.port)
    on_exit(fn -> :gen_tcp.close(socket) end)
    Wire.send_request(socket, "GET", attachment_path(context))
    assert {200, headers} = Wire.response_head(socket)
    assert Wire.header(headers, "transfer-encoding") == "chunked"
    assert {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
    assert byte_size(bytes) > 0
    assert_receive {:wire_io_opened, io}, 5_000
    assert_receive {:wire_io_waiting, ^io}, 5_000
    ref = Process.monitor(io)

    # The second read stays gated until the client has received data and reset
    # the real connection. Further reads allow the transport to report closure.
    :ok = :inet.setopts(socket, linger: {true, 0})
    :ok = :gen_tcp.close(socket)
    send(io, :client_closed)
    assert_receive {:wire_io_closed, ^io}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^io, _reason}, 5_000
  end

  defp configure_stream(mode) do
    Application.put_env(:manifold_web, :attachment_wire_test, %{owner: self(), mode: mode})
  end

  defp attachment_path(%{mailbox: mailbox, attachment: attachment}) do
    "/mailboxes/#{mailbox.id}/attachments/#{attachment.id}"
  end

  defp attachment_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "wire-attachment#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "inbox"})

    raw =
      """
      From: Sender <sender@example.net>
      To: inbox@#{domain.normalized_domain}
      Subject: Attachment wire
      Message-ID: <attachment-wire-#{suffix}@example.net>
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
    %{mailbox: mailbox, attachment: Repo.get_by!(Attachment, message_id: message.id)}
  end
end

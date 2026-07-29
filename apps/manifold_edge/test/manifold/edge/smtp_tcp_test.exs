defmodule Manifold.Edge.SMTPTCPTest do
  use Manifold.Edge.DataCase, async: false

  alias Manifold.Edge
  alias Manifold.Edge.RouteSnapshot
  alias Manifold.Edge.RouteSnapshot.Route
  alias Manifold.Edge.Schema.Delivery

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.fetch_env(:manifold_storage, :spool_dir)
    Application.put_env(:manifold_storage, :spool_dir, tmp_dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:manifold_storage, :spool_dir, value)
        :error -> Application.delete_env(:manifold_storage, :spool_dir)
      end
    end)
  end

  test "unknown recipients are rejected and known DATA is durably accepted" do
    install_snapshot()
    port = start_smtp!()
    socket = connect!(port)

    command(socket, "EHLO client.example\r\n", "250")
    command(socket, "MAIL FROM:<sender@example.net>\r\n", "250")
    command(socket, "RCPT TO:<missing@example.test>\r\n", "550")
    command(socket, "RCPT TO:<team@example.test>\r\n", "250")
    command(socket, "DATA\r\n", "354")
    command(socket, "Subject: edge\r\n\r\nBody\r\n.\r\n", "250")

    assert %Delivery{} = delivery = Repo.one!(Delivery)
    assert delivery.raw_sha256
    assert File.exists?(Path.join(delivery.spool_bundle_path, "raw.eml"))
  end

  test "missing route snapshot returns a temporary failure at RCPT TO" do
    state = %Manifold.SMTP.Session{
      peer_ip: "127.0.0.1",
      options: [
        max_message_bytes: 1024,
        max_recipients: 10,
        resolver: Manifold.Edge.SMTP,
        ingest: Manifold.Edge.SMTP
      ]
    }

    assert {:ok, state} = Manifold.SMTP.Session.handle_MAIL("sender@example.net", state)

    assert {:error, "451 4.3.0 temporary recipient lookup failure", _state} =
             Manifold.SMTP.Session.handle_RCPT("team@example.test", state)

    port = start_smtp!()
    socket = connect!(port)

    command(socket, "EHLO client.example\r\n", "250")
    command(socket, "MAIL FROM:<sender@example.net>\r\n", "250")
    command(socket, "RCPT TO:<team@example.test>\r\n", "451")
  end

  defp start_smtp! do
    port = available_port()
    ref = {:manifold_edge_smtp_test, self(), port}

    options = [
      domain: ~c"edge.example.test",
      address: {127, 0, 0, 1},
      port: port,
      sessionoptions: [
        {:allow_bare_newlines, false},
        {:callbackoptions,
         [
           max_message_bytes: 1024 * 1024,
           max_recipients: 10,
           tls_enabled?: false,
           admission: nil,
           resolver: Manifold.Edge.SMTP,
           ingest: Manifold.Edge.SMTP
         ]}
      ]
    ]

    assert {:ok, _pid} = :gen_smtp_server.start(ref, Manifold.SMTP.Session, options)
    on_exit(fn -> :gen_smtp_server.stop(ref) end)
    port
  end

  defp connect!(port) do
    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    assert String.starts_with?(recv_response(socket), "220")
    socket
  end

  defp command(socket, line, expected_code) do
    :ok = :gen_tcp.send(socket, line)
    assert String.starts_with?(recv_response(socket), expected_code)
  end

  defp recv_response(socket) do
    {:ok, first} = :gen_tcp.recv(socket, 0, 2_000)
    code = binary_part(first, 0, 3)

    if String.starts_with?(first, code <> "-") do
      recv_continuation(socket, code, first)
    else
      first
    end
  end

  defp recv_continuation(socket, code, response) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    response = response <> line

    if String.starts_with?(line, code <> " ") do
      response
    else
      recv_continuation(socket, code, response)
    end
  end

  defp available_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)
    port
  end

  defp install_snapshot do
    now = DateTime.utc_now()

    snapshot = %RouteSnapshot{
      schema_version: 1,
      revision: 1,
      digest: String.duplicate("a", 64),
      generated_at: DateTime.add(now, -60, :second),
      expires_at: DateTime.add(now, 3600, :second),
      routes: [
        %Route{
          canonical_address: "team@example.test",
          domain_id: "domain-1",
          mailbox_ids: ["mailbox-1"],
          plus_addressing_enabled: true
        }
      ]
    }

    assert {:ok, _installed} = Edge.install_route_snapshot(snapshot, now: now)
  end
end

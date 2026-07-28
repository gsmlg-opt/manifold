defmodule Manifold.SMTPTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Core.Error
  alias Manifold.Ingest.Schema.{DeliveryRecipient, InboundDelivery}
  alias Manifold.Repo

  @moduletag :tmp_dir

  defmodule TemporaryResolver do
    def resolve_recipient(_address) do
      {:error, Error.new(:temporary, :database_unavailable, "temporary failure")}
    end
  end

  defmodule AcceptingResolver do
    def resolve_recipient(address) do
      {:ok,
       %Manifold.Accounts.Route{
         original_recipient: address,
         canonical_recipient: String.downcase(address),
         plus_tag: nil,
         domain_id: Ecto.UUID.generate(),
         mailbox_ids: [Ecto.UUID.generate()]
       }}
    end
  end

  defmodule FailingIngest do
    def accept_transport(_data, _attrs, _routes) do
      {:error, Error.new(:temporary, :acceptance_failed, "injected failure")}
    end
  end

  setup %{tmp_dir: tmp_dir} do
    old_spool = Application.fetch_env!(:manifold_storage, :spool_dir)
    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)

    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))

    on_exit(fn ->
      Application.put_env(:manifold_storage, :spool_dir, old_spool)
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
    end)

    :ok
  end

  test "unknown recipient returns 550 at RCPT TO" do
    port = start_smtp!()
    socket = connect!(port)
    ehlo(socket)
    mail_from(socket)

    send_line(socket, "RCPT TO:<missing@example.test>\r\n")
    assert ["550 5.1.1" <> _] = recv_response(socket)
  end

  test "known recipient accepts DATA and creates durable delivery" do
    %{domain: domain} = mailbox_fixture()
    port = start_smtp!()
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "inbox@#{domain.normalized_domain}")
    data(socket, "Subject: ok\r\n\r\nBody\r\n")

    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert [%InboundDelivery{raw_storage_state: "spooled"}] = Repo.all(InboundDelivery)
  end

  test "multiple recipients are preserved" do
    %{domain: domain} = mailbox_fixture()
    {:ok, _mailbox} = Accounts.create_mailbox(domain, %{local_part: "second"})
    port = start_smtp!()
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "inbox@#{domain.normalized_domain}")
    rcpt_to(socket, "second@#{domain.normalized_domain}")
    data(socket, "Subject: ok\r\n\r\nBody\r\n")

    assert Repo.aggregate(DeliveryRecipient, :count) == 2
  end

  test "oversized message is rejected" do
    %{domain: domain} = mailbox_fixture()
    port = start_smtp!(max_message_bytes: 12)
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "inbox@#{domain.normalized_domain}")

    send_line(socket, "DATA\r\n")
    assert ["354" <> _] = recv_response(socket)
    send_line(socket, "Subject: too large\r\n\r\n01234567890123456789\r\n.\r\n")
    assert ["552" <> _] = recv_response(socket)
  end

  test "temporary recipient resolver failure maps to 451" do
    port = start_smtp!(resolver: TemporaryResolver)
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    send_line(socket, "RCPT TO:<inbox@example.test>\r\n")

    assert ["451 4.3.0" <> _] = recv_response(socket)
  end

  test "acceptance failure never returns 250" do
    port = start_smtp!(resolver: AcceptingResolver, ingest: FailingIngest)
    socket = connect!(port)

    ehlo(socket)
    mail_from(socket)
    rcpt_to(socket, "inbox@example.test")

    send_line(socket, "DATA\r\n")
    assert ["354" <> _] = recv_response(socket)
    send_line(socket, "Subject: no\r\n\r\nBody\r\n.\r\n")

    assert ["451 4.3.0" <> _] = recv_response(socket)
  end

  test "EHLO does not advertise AUTH or SMTPUTF8" do
    port = start_smtp!()
    socket = connect!(port)

    lines = ehlo(socket)
    response = Enum.join(lines)

    assert response =~ "8BITMIME"
    assert response =~ "PIPELINING"
    assert response =~ "SIZE"
    refute response =~ "AUTH"
    refute response =~ "SMTPUTF8"
  end

  defp mailbox_fixture do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "smtp#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_mailbox(domain, %{local_part: "inbox"})
    %{domain: domain, mailbox: mailbox}
  end

  defp start_smtp!(opts \\ []) do
    port = Keyword.get(opts, :port, 26_000 + rem(System.unique_integer([:positive]), 1000))
    ref = {:manifold_smtp_test, self(), port}

    callback_options = [
      max_message_bytes: Keyword.get(opts, :max_message_bytes, 25 * 1024 * 1024),
      max_recipients: Keyword.get(opts, :max_recipients, 100),
      tls_enabled?: false,
      resolver: Keyword.get(opts, :resolver, Manifold.Accounts),
      ingest: Keyword.get(opts, :ingest, Manifold.Ingest)
    ]

    options = [
      domain: ~c"localhost",
      address: {127, 0, 0, 1},
      port: port,
      sessionoptions: [{:allow_bare_newlines, false}, {:callbackoptions, callback_options}]
    ]

    assert {:ok, _pid} = :gen_smtp_server.start(ref, Manifold.SMTP.Session, options)

    on_exit(fn ->
      :gen_smtp_server.stop(ref)
    end)

    port
  end

  defp connect!(port) do
    assert {:ok, socket} =
             :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :line, active: false])

    assert ["220" <> _] = recv_response(socket)
    socket
  end

  defp ehlo(socket) do
    send_line(socket, "EHLO client.example\r\n")
    assert [_ | _] = lines = recv_response(socket)
    lines
  end

  defp mail_from(socket) do
    send_line(socket, "MAIL FROM:<sender@example.net>\r\n")
    assert ["250" <> _] = recv_response(socket)
  end

  defp rcpt_to(socket, address) do
    send_line(socket, "RCPT TO:<#{address}>\r\n")
    assert ["250" <> _] = recv_response(socket)
  end

  defp data(socket, body) do
    send_line(socket, "DATA\r\n")
    assert ["354" <> _] = recv_response(socket)
    send_line(socket, body <> ".\r\n")
    assert ["250 2.0.0 accepted as" <> _] = recv_response(socket)
  end

  defp send_line(socket, line), do: :ok = :gen_tcp.send(socket, line)

  defp recv_response(socket) do
    {:ok, first} = :gen_tcp.recv(socket, 0, 2_000)
    code = binary_part(first, 0, 3)
    trimmed = String.trim_trailing(first)

    if String.starts_with?(trimmed, code <> "-") do
      collect_response(socket, code, [trimmed])
    else
      [trimmed]
    end
  end

  defp collect_response(socket, code, lines) do
    {:ok, line} = :gen_tcp.recv(socket, 0, 2_000)
    trimmed = String.trim_trailing(line)

    if String.starts_with?(trimmed, code <> "-") do
      collect_response(socket, code, [trimmed | lines])
    else
      Enum.reverse([trimmed | lines])
    end
  end
end

Code.require_file("../../support/tls_peer.exs", __DIR__)

defmodule Manifold.Connectors.MailTLSIntegrationTest do
  use ExUnit.Case, async: false

  alias Manifold.Connectors.IMAP.Client, as: IMAPClient
  alias Manifold.Connectors.SMTP.Client, as: SMTPClient
  alias Manifold.TestSupport.TLSPeer

  @imap_message "Subject: TLS workflow\r\n\r\nbody"

  test "IMAP authenticates, selects, fetches a literal and logs out over direct TLS for both backends" do
    for backend <- [:otp, :ex_ssl] do
      {:ok, peer} = TLSPeer.start(&imap_session/1)

      assert {:ok, conn} =
               IMAPClient.connect(mail_settings(peer.port, "ssl", backend))

      assert {:ok, %{uidvalidity: 42}} = IMAPClient.select(conn, "INBOX")
      assert {:ok, @imap_message} = IMAPClient.uid_fetch_rfc822(conn, 1)
      assert :ok = IMAPClient.logout(conn)
      assert :ok = TLSPeer.stop(peer)
    end
  end

  test "IMAP STARTTLS uses the selected backend after the tagged response boundary is clean" do
    for backend <- [:otp, :ex_ssl] do
      {:ok, peer} = start_imap_starttls(&imap_starttls_session/1)

      assert {:ok, conn} = IMAPClient.connect(mail_settings(peer.port, "starttls", backend))
      assert {:ok, %{uidvalidity: 42}} = IMAPClient.select(conn, "INBOX")
      assert {:ok, @imap_message} = IMAPClient.uid_fetch_rfc822(conn, 1)
      assert :ok = IMAPClient.logout(conn)
      assert :ok = stop_starttls_peer(peer)
    end
  end

  test "IMAP rejects unexpected plaintext after a successful STARTTLS response" do
    {:ok, peer} =
      start_starttls_peer(fn tcp ->
        :ok = :gen_tcp.send(tcp, "* OK local IMAP ready\r\n")
        assert_tcp_line(tcp, "A1 STARTTLS")
        :ok = :gen_tcp.send(tcp, "A1 OK begin TLS\r\nunexpected plaintext")
        assert {:error, :closed} = :gen_tcp.recv(tcp, 0, 5_000)
        :ok
      end)

    assert {:error, _} = IMAPClient.connect(mail_settings(peer.port, "starttls", :ex_ssl))
    assert :ok = stop_starttls_peer(peer)
  end

  test "IMAP does not accept a malformed tagged STARTTLS success token" do
    {:ok, peer} =
      start_starttls_peer(fn tcp ->
        :ok = :gen_tcp.send(tcp, "* OK local IMAP ready\r\n")
        assert_tcp_line(tcp, "A1 STARTTLS")
        :ok = :gen_tcp.send(tcp, "A1 OKAY begin TLS\r\n")
        :ok = :gen_tcp.close(tcp)
      end)

    assert {:error, %{class: :temporary, code: :recv_failed}} =
             IMAPClient.connect(mail_settings(peer.port, "starttls", :ex_ssl))

    assert :ok = stop_starttls_peer(peer)
  end

  test "IMAP closes the plaintext connection after STARTTLS is rejected" do
    {:ok, peer} =
      start_starttls_peer(fn tcp ->
        :ok = :gen_tcp.send(tcp, "* OK local IMAP ready\r\n")
        assert_tcp_line(tcp, "A1 STARTTLS")
        :ok = :gen_tcp.send(tcp, "A1 NO TLS unavailable\r\n")
        assert {:error, :closed} = :gen_tcp.recv(tcp, 0, 5_000)
        :ok
      end)

    assert {:error, %{class: :temporary, code: :command_no}} =
             IMAPClient.connect(mail_settings(peer.port, "starttls", :ex_ssl))

    assert :ok = stop_starttls_peer(peer)
  end

  test "IMAP reports a certificate failure through the existing connection error category" do
    {:ok, peer} = TLSPeer.start(fn _socket -> :ok end, certificate: :expired)

    assert {:error, %{class: :temporary, code: :connect_failed}} =
             IMAPClient.connect(mail_settings(peer.port, "ssl", :ex_ssl))

    assert {:handshake_error, _} = TLSPeer.stop(peer)
  end

  test "IMAP closes an authenticated TLS connection after LOGIN is rejected" do
    {:ok, peer} =
      TLSPeer.start(fn socket ->
        :ok = :ssl.send(socket, "* OK local IMAP ready\r\n")
        assert_line(socket, "A1 LOGIN \"user@exssl.test\" \"local-test-password\"")
        :ok = :ssl.send(socket, "A1 NO authentication rejected\r\n")
        assert {:error, :closed} = :ssl.recv(socket, 0, 5_000)
        :ok
      end)

    assert {:error, %{class: :reconnect, code: :auth_failed}} =
             IMAPClient.connect(mail_settings(peer.port, "ssl", :ex_ssl))

    assert :ok = TLSPeer.stop(peer)
  end

  test "SMTP authenticates and submits over direct TLS for both backends" do
    for backend <- [:otp, :ex_ssl] do
      {:ok, peer} = TLSPeer.start(&smtp_session/1)

      assert {:ok, conn} = SMTPClient.connect(mail_settings(peer.port, "ssl", backend))
      assert {:ok, %{response: "250 queued"}} = SMTPClient.submit(conn, submission())
      assert :ok = SMTPClient.quit(conn)
      assert :ok = TLSPeer.stop(peer)
    end
  end

  test "SMTP STARTTLS authenticates and submits through the selected backend" do
    for backend <- [:otp, :ex_ssl] do
      {:ok, peer} = start_smtp_starttls(&smtp_starttls_session/1)

      assert {:ok, conn} = SMTPClient.connect(mail_settings(peer.port, "starttls", backend))
      assert {:ok, %{response: "250 queued"}} = SMTPClient.submit(conn, submission())
      assert :ok = SMTPClient.quit(conn)
      assert :ok = stop_starttls_peer(peer)
    end
  end

  test "SMTP rejects unexpected plaintext after a successful STARTTLS response" do
    {:ok, peer} =
      start_starttls_peer(fn tcp ->
        :ok = :gen_tcp.send(tcp, "220 local SMTP ready\r\n")
        assert_tcp_line(tcp, "EHLO 127.0.0.1")
        :ok = :gen_tcp.send(tcp, "250-local\r\n250 STARTTLS\r\n")
        assert_tcp_line(tcp, "STARTTLS")
        :ok = :gen_tcp.send(tcp, "220 begin TLS\r\nunexpected plaintext")
        assert {:error, :closed} = :gen_tcp.recv(tcp, 0, 5_000)
        :ok
      end)

    assert {:error, %{class: :temporary, code: :connect_failed}} =
             SMTPClient.connect(mail_settings(peer.port, "starttls", :ex_ssl))

    assert :ok = stop_starttls_peer(peer)
  end

  test "SMTP reports certificate and transport failures without fallback" do
    {:ok, peer} = TLSPeer.start(fn _socket -> :ok end, certificate: :expired)

    assert {:error, %{class: :permanent, code: :tls_failed}} =
             SMTPClient.connect(mail_settings(peer.port, "ssl", :ex_ssl))

    assert {:handshake_error, _} = TLSPeer.stop(peer)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    assert {:error, %{class: :temporary, code: :connect_failed}} =
             SMTPClient.connect(mail_settings(port, "ssl", :ex_ssl))

    assert {:error, %{class: :temporary, code: :connect_failed}} =
             IMAPClient.connect(mail_settings(port, "ssl", :ex_ssl))
  end

  test "SMTP closes an authenticated TLS connection after AUTH is rejected" do
    {:ok, peer} =
      TLSPeer.start(fn socket ->
        :ok = :ssl.send(socket, "220 local SMTP ready\r\n")
        assert_line(socket, "EHLO 127.0.0.1")
        :ok = :ssl.send(socket, "250-local\r\n250 AUTH LOGIN\r\n")
        assert_line(socket, "AUTH LOGIN")
        :ok = :ssl.send(socket, "334 username\r\n")
        assert_line(socket, Base.encode64("user@exssl.test"))
        :ok = :ssl.send(socket, "334 password\r\n")
        assert_line(socket, Base.encode64("local-test-password"))
        :ok = :ssl.send(socket, "535 rejected\r\n")
        assert {:error, :closed} = :ssl.recv(socket, 0, 5_000)
        :ok
      end)

    assert {:error, %{class: :reconnect, code: :auth_failed}} =
             SMTPClient.connect(mail_settings(peer.port, "ssl", :ex_ssl))

    assert :ok = TLSPeer.stop(peer)
  end

  test "SMTP closes the TLS connection after EHLO is rejected" do
    {:ok, peer} =
      TLSPeer.start(fn socket ->
        :ok = :ssl.send(socket, "220 local SMTP ready\r\n")
        assert_line(socket, "EHLO 127.0.0.1")
        :ok = :ssl.send(socket, "550 EHLO rejected\r\n")
        assert {:error, :closed} = :ssl.recv(socket, 0, 5_000)
        :ok
      end)

    assert {:error, %{class: :temporary, code: :ehlo_failed}} =
             SMTPClient.connect(mail_settings(peer.port, "ssl", :ex_ssl))

    assert :ok = TLSPeer.stop(peer)
  end

  defp mail_settings(port, tls_mode, backend) do
    tls_overrides =
      Enum.filter(TLSPeer.client_options(), fn
        {key, _value} ->
          key in [
            :cacerts,
            :cacertfile,
            :server_name_indication,
            :customize_hostname_check,
            :versions,
            :ex_ssl
          ]

        _mode ->
          false
      end)

    %{
      host: "127.0.0.1",
      port: port,
      tls_mode: tls_mode,
      username: "user@exssl.test",
      password: "local-test-password",
      tls: [backend: backend, options: tls_overrides]
    }
  end

  defp submission do
    %{
      envelope_from: "user@exssl.test",
      recipients: ["recipient@exssl.test"],
      raw_message: "From: user@exssl.test\nTo: recipient@exssl.test\n\nlocal TLS message\n"
    }
  end

  defp imap_session(socket) do
    :ok = :ssl.send(socket, "* OK local IMAP ready\r\n")
    assert_line(socket, "A1 LOGIN \"user@exssl.test\" \"local-test-password\"")
    :ok = :ssl.send(socket, "A1 OK authenticated\r\n")
    assert_line(socket, "A2 SELECT INBOX")
    :ok = :ssl.send(socket, "* OK [UIDVALIDITY 42] selected\r\nA2 OK selected\r\n")
    assert_line(socket, "A3 UID FETCH 1 (BODY.PEEK[])")

    :ok =
      :ssl.send(
        socket,
        "* 1 FETCH (BODY[] {#{byte_size(@imap_message)}}\r\n" <>
          @imap_message <> ")\r\nA3 OK fetched\r\n"
      )

    assert_line(socket, "A4 LOGOUT")
    :ok = :ssl.send(socket, "* BYE local logout\r\nA4 OK logout\r\n")
    :ok
  end

  defp imap_starttls_session(socket) do
    :ok = :ssl.send(socket, "A2 OK authenticated\r\n")
    assert_line(socket, "A3 SELECT INBOX")
    :ok = :ssl.send(socket, "* OK [UIDVALIDITY 42] selected\r\nA3 OK selected\r\n")
    assert_line(socket, "A4 UID FETCH 1 (BODY.PEEK[])")

    :ok =
      :ssl.send(
        socket,
        "* 1 FETCH (BODY[] {#{byte_size(@imap_message)}}\r\n" <>
          @imap_message <> ")\r\nA4 OK fetched\r\n"
      )

    assert_line(socket, "A5 LOGOUT")
    :ok = :ssl.send(socket, "* BYE local logout\r\nA5 OK logout\r\n")
    :ok
  end

  defp smtp_session(socket) do
    :ok = :ssl.send(socket, "220 local SMTP ready\r\n")
    smtp_authenticated_session(socket)
  end

  defp smtp_starttls_session(socket), do: smtp_authenticated_session(socket)

  defp smtp_authenticated_session(socket) do
    assert_line(socket, "EHLO 127.0.0.1")
    :ok = :ssl.send(socket, "250-local\r\n250 AUTH LOGIN\r\n")
    assert_line(socket, "AUTH LOGIN")
    :ok = :ssl.send(socket, "334 username\r\n")
    assert_line(socket, Base.encode64("user@exssl.test"))
    :ok = :ssl.send(socket, "334 password\r\n")
    assert_line(socket, Base.encode64("local-test-password"))
    :ok = :ssl.send(socket, "235 authenticated\r\n")
    assert_line(socket, "MAIL FROM:<user@exssl.test>")
    :ok = :ssl.send(socket, "250 sender\r\n")
    assert_line(socket, "RCPT TO:<recipient@exssl.test>")
    :ok = :ssl.send(socket, "250 recipient\r\n")
    assert_line(socket, "DATA")
    :ok = :ssl.send(socket, "354 data\r\n")
    {:ok, _message} = recv_until(socket, "\r\n.\r\n")
    :ok = :ssl.send(socket, "250 queued\r\n")
    assert_line(socket, "QUIT")
    :ok = :ssl.send(socket, "221 bye\r\n")
    :ok
  end

  defp start_imap_starttls(handler) do
    start_starttls_peer(fn tcp ->
      :ok = :gen_tcp.send(tcp, "* OK local IMAP ready\r\n")
      assert_tcp_line(tcp, "A1 STARTTLS")
      :ok = :gen_tcp.send(tcp, "A1 OK begin TLS\r\n")
      socket = handshake(tcp)
      assert_line(socket, "A2 LOGIN \"user@exssl.test\" \"local-test-password\"")
      handler.(socket)
    end)
  end

  defp start_smtp_starttls(handler) do
    start_starttls_peer(fn tcp ->
      :ok = :gen_tcp.send(tcp, "220 local SMTP ready\r\n")
      assert_tcp_line(tcp, "EHLO 127.0.0.1")
      :ok = :gen_tcp.send(tcp, "250-local\r\n250 STARTTLS\r\n")
      assert_tcp_line(tcp, "STARTTLS")
      :ok = :gen_tcp.send(tcp, "220 begin TLS\r\n")
      handler.(handshake(tcp))
    end)
  end

  defp start_starttls_peer(handler) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, tcp} = :gen_tcp.accept(listener, 5_000)
        handler.(tcp)
      end)

    {:ok, %{listener: listener, task: task, port: port}}
  end

  defp stop_starttls_peer(%{listener: listener, task: task}) do
    _ = :gen_tcp.close(listener)
    Task.await(task, 6_000)
  end

  defp handshake(tcp) do
    %{certfile: certfile, keyfile: keyfile} = TLSPeer.certificates()

    {:ok, socket} =
      :ssl.handshake(tcp,
        certfile: String.to_charlist(certfile),
        keyfile: String.to_charlist(keyfile),
        versions: [:"tlsv1.3"],
        verify: :verify_none,
        active: false,
        mode: :binary,
        packet: :raw
      )

    socket
  end

  defp assert_line(socket, expected) do
    assert {:ok, ^expected <> "\r\n"} = :ssl.recv(socket, 0, 5_000)
  end

  defp assert_tcp_line(socket, expected) do
    assert {:ok, ^expected <> "\r\n"} = :gen_tcp.recv(socket, 0, 5_000)
  end

  defp recv_until(socket, suffix, bytes \\ "") do
    if String.ends_with?(bytes, suffix) do
      {:ok, bytes}
    else
      with {:ok, more} <- :ssl.recv(socket, 0, 5_000),
           true <- byte_size(bytes) + byte_size(more) <= 2_000_000 do
        recv_until(socket, suffix, bytes <> more)
      else
        false -> {:error, :too_large}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

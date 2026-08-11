defmodule Manifold.Connectors.SMTP.ClientSubmissionTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.Provider.Error
  alias Manifold.Connectors.SMTP.Client

  @submission %{
    envelope_from: "sender@example.net",
    recipients: ["to@example.net", "hidden@example.net"],
    raw_message:
      "From: sender@example.net\nTo: to@example.net\nMessage-ID: <stable@manifold.local>\n\nHello\n.leading\r\n..already\rlast\r\n"
  }

  test "submits every envelope recipient before dot-stuffed CRLF DATA and quits" do
    expected_data =
      "From: sender@example.net\r\n" <>
        "To: to@example.net\r\n" <>
        "Message-ID: <stable@manifold.local>\r\n\r\n" <>
        "Hello\r\n..leading\r\n...already\r\nlast\r\n.\r\n"

    {conn, server} =
      start_server([
        command("MAIL FROM:<sender@example.net>", "250 2.1.0 sender ok"),
        command("RCPT TO:<to@example.net>", "250 2.1.5 recipient ok"),
        command("RCPT TO:<hidden@example.net>", "251 2.1.5 forwarded"),
        command("DATA", "354 end with dot"),
        data(expected_data, "250 2.0.0 queued as private-server-id"),
        command("QUIT", "221 bye")
      ])

    assert {:ok, %{response: "250 2.0.0 queued as private-server-id"}} =
             Client.submit(conn, @submission)

    assert :ok = Client.quit(conn)
    assert :ok = Task.await(server)
  end

  test "resets without DATA when a recipient is temporarily rejected" do
    {conn, server} =
      start_server([
        command("MAIL FROM:<sender@example.net>", "250 sender ok"),
        command("RCPT TO:<to@example.net>", "250 recipient ok"),
        command("RCPT TO:<hidden@example.net>", "450 mailbox busy"),
        command("RSET", "250 reset"),
        command("QUIT", "221 bye")
      ])

    assert {:error, %Error{class: :temporary, code: :recipient_rejected, message: message}} =
             Client.submit(conn, @submission)

    refute message =~ "mailbox busy"
    assert :ok = Client.quit(conn)
    assert :ok = Task.await(server)
  end

  test "resets without DATA when a recipient is permanently rejected" do
    {conn, server} =
      start_server([
        command("MAIL FROM:<sender@example.net>", "250 sender ok"),
        command("RCPT TO:<to@example.net>", "550 no such recipient"),
        command("RSET", "250 reset"),
        command("QUIT", "221 bye")
      ])

    assert {:error, %Error{class: :permanent, code: :recipient_rejected, message: message}} =
             Client.submit(conn, @submission)

    refute message =~ "no such recipient"
    assert :ok = Client.quit(conn)
    assert :ok = Task.await(server)
  end

  test "classifies a disconnect before DATA as definitely temporary" do
    {conn, server} =
      start_server([
        close_after_command("MAIL FROM:<sender@example.net>")
      ])

    assert {:error, %Error{class: :temporary, code: :recv_failed}} =
             Client.submit(conn, @submission)

    assert :ok = Client.quit(conn)
    assert :ok = Task.await(server)
  end

  test "classifies a disconnect after the complete terminator as uncertain" do
    expected_data =
      "From: sender@example.net\r\n" <>
        "To: to@example.net\r\n" <>
        "Message-ID: <stable@manifold.local>\r\n\r\n" <>
        "Hello\r\n..leading\r\n...already\r\nlast\r\n.\r\n"

    {conn, server} =
      start_server([
        command("MAIL FROM:<sender@example.net>", "250 sender ok"),
        command("RCPT TO:<to@example.net>", "250 recipient ok"),
        command("RCPT TO:<hidden@example.net>", "250 recipient ok"),
        command("DATA", "354 send data"),
        close_after_data(expected_data)
      ])

    assert {:error,
            %Error{
              class: :uncertain,
              code: :acceptance_unknown,
              message: "SMTP may have accepted the message"
            }} = Client.submit(conn, @submission)

    assert :ok = Client.quit(conn)
    assert :ok = Task.await(server)
  end

  test "rejects command injection in envelope addresses before socket I/O" do
    assert {:error, %Error{class: :permanent, code: :invalid_envelope_address}} =
             Client.submit(%Client{socket: :unused, buffer: ""}, %{
               @submission
               | envelope_from: "sender@example.net\r\nRCPT TO:<attacker@example.net>"
             })

    assert {:error, %Error{class: :permanent, code: :invalid_envelope_address}} =
             Client.submit(%Client{socket: :unused, buffer: ""}, %{
               @submission
               | recipients: ["to@example.net", "hidden@example.net\nDATA"]
             })
  end

  test "does not expose multiline server replies from connection setup" do
    {port, server} =
      start_connect_server([
        reply("220 ready"),
        command(
          "EHLO 127.0.0.1",
          "500-private-server-first-line\r\n500 private-server-final-line"
        )
      ])

    assert {:error, %Error{class: :temporary, code: :ehlo_failed} = error} =
             Client.connect(%{
               host: "127.0.0.1",
               port: port,
               tls_mode: "starttls",
               username: "sender@example.net",
               password: "private-password"
             })

    refute inspect(error) =~ "private-server"
    refute inspect(error) =~ "private-password"
    assert :ok = Task.await(server)
  end

  defp command(expected, reply), do: {:command, expected <> "\r\n", reply <> "\r\n"}
  defp reply(reply), do: {:reply, reply <> "\r\n"}
  defp close_after_command(expected), do: {:close_after_command, expected <> "\r\n"}
  defp data(expected, reply), do: {:data, expected, reply <> "\r\n"}
  defp close_after_data(expected), do: {:close_after_data, expected}

  defp start_server(script) do
    {_listen, port, server} = start_listening_server(script)

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 1_000)

    {%Client{socket: {:tcp, socket}, buffer: ""}, server}
  end

  defp start_connect_server(script) do
    {_listen, port, server} = start_listening_server(script)
    {port, server}
  end

  defp start_listening_server(script) do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 1_000)
        :ok = :gen_tcp.close(listen)
        run_script(socket, script)
      end)

    {listen, port, server}
  end

  defp run_script(socket, script) do
    Enum.reduce_while(script, :ok, fn
      {:reply, reply}, :ok ->
        assert :ok = :gen_tcp.send(socket, reply)
        {:cont, :ok}

      {:command, expected, reply}, :ok ->
        assert {:ok, ^expected} = :gen_tcp.recv(socket, 0, 1_000)
        assert :ok = :gen_tcp.send(socket, reply)
        {:cont, :ok}

      {:data, expected, reply}, :ok ->
        assert {:ok, ^expected} = recv_data(socket, "")
        assert :ok = :gen_tcp.send(socket, reply)
        {:cont, :ok}

      {:close_after_command, expected}, :ok ->
        assert {:ok, ^expected} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.close(socket)
        {:halt, :ok}

      {:close_after_data, expected}, :ok ->
        assert {:ok, ^expected} = recv_data(socket, "")
        :ok = :gen_tcp.close(socket)
        {:halt, :ok}
    end)
  end

  defp recv_data(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, ".\r\n" = terminator} -> {:ok, acc <> terminator}
      {:ok, line} -> recv_data(socket, acc <> line)
      {:error, reason} -> {:error, reason}
    end
  end
end

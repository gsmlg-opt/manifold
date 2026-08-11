defmodule Manifold.Connectors.SMTP.ClientSubmissionTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.Provider.Error
  alias Manifold.Connectors.SMTP.Client

  defmodule ScriptedSocket do
    def start(opts) do
      Agent.start_link(fn ->
        %{
          closed?: false,
          fail_body?: Keyword.get(opts, :fail_body?, false),
          fail_terminator?: Keyword.get(opts, :fail_terminator?, false),
          recv_delay_ms: Keyword.get(opts, :recv_delay_ms, 0),
          replies: Keyword.fetch!(opts, :replies),
          writes: []
        }
      end)
    end

    def send(pid, data) do
      Agent.get_and_update(pid, fn state ->
        state = %{state | writes: state.writes ++ [data]}

        cond do
          data == "\r\n.\r\n" and state.fail_terminator? -> {{:error, :closed}, state}
          String.starts_with?(data, "From:") and state.fail_body? -> {{:error, :closed}, state}
          true -> {:ok, state}
        end
      end)
    end

    def recv(pid), do: recv(pid, 30_000)

    def recv(pid, timeout) do
      delay = Agent.get(pid, & &1.recv_delay_ms)

      if delay >= timeout do
        {:error, :timeout}
      else
        Process.sleep(delay)

        Agent.get_and_update(pid, fn
          %{replies: [reply | rest]} = state -> {{:ok, reply}, %{state | replies: rest}}
          state -> {{:error, :closed}, state}
        end)
      end
    end

    def close(pid) do
      Agent.update(pid, &%{&1 | closed?: true})
      :ok
    end

    def state(pid), do: Agent.get(pid, & &1)
  end

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

  test "runs greeting, EHLO, authentication, submission, and QUIT as one session" do
    {:ok, socket} =
      ScriptedSocket.start(
        replies: [
          "220 fixture ready\r\n",
          "250-fixture\r\n250 AUTH LOGIN PLAIN\r\n",
          "334 username\r\n",
          "334 password\r\n",
          "235 authenticated\r\n",
          "250 sender\r\n",
          "250 recipient\r\n",
          "250 recipient\r\n",
          "354 data\r\n",
          "250 accepted\r\n",
          "221 bye\r\n"
        ]
      )

    fixture_socket = {:adapter, ScriptedSocket, socket}

    assert {:ok, conn} =
             Client.connect(%{
               host: "smtp.fixture",
               port: 465,
               tls_mode: "tls",
               username: "sender@example.net",
               password: "private-password",
               fixture_socket: fixture_socket
             })

    assert {:ok, %{response: "250 accepted"}} = Client.submit(conn, @submission)
    assert :ok = Client.quit(conn)

    assert ScriptedSocket.state(socket).writes == [
             "EHLO smtp.fixture\r\n",
             "AUTH LOGIN\r\n",
             Base.encode64("sender@example.net") <> "\r\n",
             Base.encode64("private-password") <> "\r\n",
             "MAIL FROM:<sender@example.net>\r\n",
             "RCPT TO:<to@example.net>\r\n",
             "RCPT TO:<hidden@example.net>\r\n",
             "DATA\r\n",
             "From: sender@example.net\r\n" <>
               "To: to@example.net\r\n" <>
               "Message-ID: <stable@manifold.local>\r\n\r\n" <>
               "Hello\r\n..leading\r\n...already\r\nlast",
             "\r\n.\r\n",
             "QUIT\r\n"
           ]
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

  test "keeps a DATA body write failure definite and does not attempt the terminator" do
    {:ok, socket} =
      ScriptedSocket.start(
        fail_body?: true,
        replies: ["250 sender\r\n", "250 recipient\r\n", "250 recipient\r\n", "354 data\r\n"]
      )

    conn = %Client{socket: {:adapter, ScriptedSocket, socket}, buffer: ""}

    assert {:error, %Error{class: :temporary, code: :send_failed}} =
             Client.submit(conn, @submission)

    state = ScriptedSocket.state(socket)
    assert state.closed?
    refute "\r\n.\r\n" in state.writes
  end

  test "treats any terminator write failure as acceptance uncertainty" do
    {:ok, socket} =
      ScriptedSocket.start(
        fail_terminator?: true,
        replies: ["250 sender\r\n", "250 recipient\r\n", "250 recipient\r\n", "354 data\r\n"]
      )

    conn = %Client{socket: {:adapter, ScriptedSocket, socket}, buffer: ""}

    assert {:error, %Error{class: :uncertain, code: :acceptance_unknown}} =
             Client.submit(conn, @submission)

    assert %{
             closed?: true,
             writes: [
               "MAIL FROM:<sender@example.net>\r\n",
               "RCPT TO:<to@example.net>\r\n",
               "RCPT TO:<hidden@example.net>\r\n",
               "DATA\r\n",
               body,
               "\r\n.\r\n"
             ]
           } = ScriptedSocket.state(socket)

    assert body ==
             "From: sender@example.net\r\n" <>
               "To: to@example.net\r\n" <>
               "Message-ID: <stable@manifold.local>\r\n\r\n" <>
               "Hello\r\n..leading\r\n...already\r\nlast"
  end

  test "rejects inconsistent multiline reply codes before DATA without exposing the reply" do
    {conn, server} =
      start_server([
        command("MAIL FROM:<sender@example.net>", "250-private-first\r\n550 private-final"),
        command("QUIT", "221 bye")
      ])

    assert {:error, %Error{class: :temporary, code: :bad_reply} = error} =
             Client.submit(conn, @submission)

    refute inspect(error) =~ "private"
    assert :ok = Client.quit(conn)
    assert :ok = Task.await(server)
  end

  test "treats inconsistent multiline final DATA reply as uncertain" do
    expected_data =
      "From: sender@example.net\r\n" <>
        "To: to@example.net\r\n" <>
        "Message-ID: <stable@manifold.local>\r\n\r\n" <>
        "Hello\r\n..leading\r\n...already\r\nlast\r\n.\r\n"

    {conn, server} =
      start_server([
        command("MAIL FROM:<sender@example.net>", "250 sender"),
        command("RCPT TO:<to@example.net>", "250 recipient"),
        command("RCPT TO:<hidden@example.net>", "250 recipient"),
        command("DATA", "354 data"),
        data(expected_data, "250-private-first\r\n550 private-final")
      ])

    assert {:error, %Error{class: :uncertain, code: :acceptance_unknown} = error} =
             Client.submit(conn, @submission)

    refute inspect(error) =~ "private"
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

  test "normalizes a real localhost connection refusal without leaking socket details" do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen)
    :ok = :gen_tcp.close(listen)

    assert {:error, %Error{class: :temporary, code: :connect_failed} = error} =
             Client.connect(%{
               host: "127.0.0.1",
               port: port,
               tls_mode: "starttls",
               username: "sender@example.net",
               password: "private-password"
             })

    refute inspect(error) =~ "econnrefused"
    refute inspect(error) =~ "private-password"
  end

  test "rejects invalid connection configuration as permanent without raising" do
    invalid_settings = [
      %{
        host: "smtp.example.net",
        port: 587,
        tls_mode: "plain",
        username: "sender@example.net",
        password: "private-password"
      },
      %{
        host: "",
        port: 587,
        tls_mode: "starttls",
        username: "sender@example.net",
        password: "private-password"
      },
      %{
        host: "smtp.example.net",
        port: "not-a-port",
        tls_mode: "starttls",
        username: "sender@example.net",
        password: "private-password"
      },
      %{}
    ]

    for settings <- invalid_settings do
      assert {:error, %Error{class: :permanent, code: :invalid_config} = error} =
               Client.connect(settings)

      refute inspect(error) =~ "private-password"
    end
  end

  test "rejects reply codes outside the SMTP range before DATA" do
    for invalid_code <- ["000", "199", "600", "999"] do
      {conn, server} =
        start_server([
          command("MAIL FROM:<sender@example.net>", "#{invalid_code} private-invalid-code"),
          command("QUIT", "221 bye")
        ])

      assert {:error, %Error{class: :temporary, code: :bad_reply} = error} =
               Client.submit(conn, @submission)

      refute inspect(error) =~ "private-invalid-code"
      assert :ok = Client.quit(conn)
      assert :ok = Task.await(server)
    end
  end

  test "treats invalid or malformed reply codes after the terminator as uncertain" do
    for reply <- [
          "000 invalid\r\n",
          "199 invalid\r\n",
          "600 invalid\r\n",
          "999 invalid\r\n",
          "bad\r\n"
        ] do
      {:ok, socket} =
        ScriptedSocket.start(
          replies: [
            "250 sender\r\n",
            "250 recipient\r\n",
            "250 recipient\r\n",
            "354 data\r\n",
            reply
          ]
        )

      conn = %Client{socket: {:adapter, ScriptedSocket, socket}, buffer: ""}

      assert {:error, %Error{class: :uncertain, code: :acceptance_unknown}} =
               Client.submit(conn, @submission)
    end
  end

  test "classifies final DATA replies by acceptance certainty" do
    cases = [
      {"250 accepted\r\n", :accepted},
      {"450 temporary rejection\r\n", {:temporary, :message_rejected}},
      {"550 permanent rejection\r\n", {:permanent, :message_rejected}},
      {"200 context-invalid success\r\n", {:uncertain, :acceptance_unknown}},
      {"251 context-invalid success\r\n", {:uncertain, :acceptance_unknown}},
      {"252 context-invalid success\r\n", {:uncertain, :acceptance_unknown}},
      {"300 context-invalid intermediate\r\n", {:uncertain, :acceptance_unknown}},
      {"354 context-invalid intermediate\r\n", {:uncertain, :acceptance_unknown}}
    ]

    for {reply, expected} <- cases do
      {:ok, socket} =
        ScriptedSocket.start(
          replies: [
            "250 sender\r\n",
            "250 recipient\r\n",
            "250 recipient\r\n",
            "354 data\r\n",
            reply
          ]
        )

      conn = %Client{socket: {:adapter, ScriptedSocket, socket}, buffer: ""}

      case expected do
        :accepted ->
          assert {:ok, %{response: "250 accepted"}} = Client.submit(conn, @submission)

        {class, code} ->
          assert {:error, %Error{class: ^class, code: ^code} = error} =
                   Client.submit(conn, @submission)

          refute inspect(error) =~ "context-invalid"
      end
    end
  end

  test "bounds SMTP reply line length, continuation count, and total size" do
    oversized_line = "250 " <> String.duplicate("x", 507) <> "\r\n"

    {:ok, oversized_socket} =
      ScriptedSocket.start(replies: [oversized_line])

    oversized_conn = %Client{
      socket: {:adapter, ScriptedSocket, oversized_socket},
      buffer: ""
    }

    assert {:error, %Error{class: :temporary, code: :bad_reply}} =
             Client.submit(oversized_conn, @submission)

    too_many_lines =
      Enum.map_join(1..101, "", fn _index -> "250-continuing\r\n" end) <> "250 done\r\n"

    {:ok, line_count_socket} = ScriptedSocket.start(replies: [too_many_lines])

    line_count_conn = %Client{
      socket: {:adapter, ScriptedSocket, line_count_socket},
      buffer: ""
    }

    assert {:error, %Error{class: :temporary, code: :bad_reply}} =
             Client.submit(line_count_conn, @submission)

    oversized_reply =
      Enum.map_join(1..33, "", fn _index ->
        "250-" <> String.duplicate("x", 494) <> "\r\n"
      end) <> "250 done\r\n"

    {:ok, total_size_socket} = ScriptedSocket.start(replies: [oversized_reply])

    total_size_conn = %Client{
      socket: {:adapter, ScriptedSocket, total_size_socket},
      buffer: ""
    }

    assert {:error, %Error{class: :temporary, code: :bad_reply}} =
             Client.submit(total_size_conn, @submission)
  end

  test "uses one monotonic deadline for a multiline reply" do
    {:ok, socket} =
      ScriptedSocket.start(
        recv_delay_ms: 4,
        replies: ["250-continuing\r\n", "250 done\r\n"]
      )

    conn =
      %Client{socket: {:adapter, ScriptedSocket, socket}, buffer: ""}
      |> Map.put(:reply_timeout_ms, 6)

    assert {:error, %Error{class: :temporary, code: :timeout}} =
             Client.submit(conn, @submission)
  end

  test "frames newline and empty-line variants with one exact terminator" do
    cases = [
      {"Body", "Body"},
      {"Body\n", "Body"},
      {"Body\n\n", "Body\r\n"},
      {"", ""},
      {"\n", ""},
      {".first\n.\n\n", "..first\r\n..\r\n"}
    ]

    for {raw_message, expected_body} <- cases do
      {:ok, socket} =
        ScriptedSocket.start(
          replies: [
            "250 sender\r\n",
            "250 recipient\r\n",
            "250 recipient\r\n",
            "354 data\r\n",
            "250 accepted\r\n"
          ]
        )

      conn = %Client{socket: {:adapter, ScriptedSocket, socket}, buffer: ""}

      assert {:ok, _result} = Client.submit(conn, %{@submission | raw_message: raw_message})

      assert Enum.take(ScriptedSocket.state(socket).writes, -2) == [
               expected_body,
               "\r\n.\r\n"
             ]
    end
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

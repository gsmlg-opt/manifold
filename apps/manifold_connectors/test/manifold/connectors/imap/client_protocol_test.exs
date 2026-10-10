defmodule Manifold.Connectors.IMAP.ClientProtocolTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.IMAP.Client
  alias Manifold.Connectors.Provider.Error

  test "parse_search_response extracts uids" do
    assert {:ok, [1, 2, 9]} =
             Client.parse_search_response(["* SEARCH 1 2 9", "A3 OK SEARCH completed"])
  end

  test "parse_search_response handles empty search" do
    assert {:ok, []} = Client.parse_search_response(["* SEARCH", "A3 OK SEARCH completed"])
  end

  test "parse_uidvalidity reads OK response code" do
    lines = [
      "* 2 EXISTS",
      "* OK [UIDVALIDITY 42] UIDs valid",
      "* OK [UIDNEXT 3] Predicted next UID"
    ]

    assert {:ok, 42} = Client.parse_uidvalidity(lines)
    assert 3 = Client.parse_uidnext(lines)
  end

  test "extract_rfc822 reads literal body" do
    raw = "Subject: hi\r\n\r\nbody\r\n"
    size = byte_size(raw)

    lines = [
      "* 1 FETCH (UID 1 RFC822 {#{size}}\n#{raw})",
      "A5 OK FETCH completed"
    ]

    assert {:ok, ^raw} = Client.extract_rfc822(lines)
  end

  test "extract_rfc822 treats absent FETCH as a missing message" do
    assert {:error, %Error{code: :not_found}} = Client.extract_rfc822([])
    assert {:error, %Error{code: :not_found}} = Client.extract_rfc822(["* 2 EXISTS"])
  end

  test "extract_rfc822 retains parse errors for malformed FETCH" do
    for response <- [
          "* 1 FETCH (UID 447 BODY[] NIL)",
          "* 1 FETCH UID 447 BODY[] NIL",
          "* 1 FETCH"
        ] do
      assert {:error, %Error{code: :fetch_parse_failed}} = Client.extract_rfc822([response])
    end
  end

  test "uid_fetch_rfc822 reads a literal without marking the message seen" do
    raw = "Subject: hi\r\n\r\nbody\r\n"

    {result, command} =
      fetch_over_tcp("* 1 FETCH (UID 232 BODY[] {#{byte_size(raw)}}\r\n#{raw})\r\n")

    assert {:ok, ^raw} = result
    assert command == "A1 UID FETCH 232 (BODY.PEEK[])\r\n"
  end

  test "uid_fetch_rfc822 classifies tagged OK without FETCH as not_found" do
    {result, _command} = fetch_over_tcp("")
    assert {:error, %Error{code: :not_found}} = result
  end

  test "parse_flags_response maps uid to flags and INTERNALDATE" do
    lines = [
      "* 1 FETCH (FLAGS (\\Seen \\Answered) UID 10 INTERNALDATE \"06-Aug-2026 15:20:33 +0800\")",
      "* 2 FETCH (UID 11 FLAGS (\\Flagged) INTERNALDATE \"01-Jan-2026 00:00:00 +0000\")",
      "* 3 FETCH (UID 12 FLAGS ())",
      "A6 OK FETCH completed"
    ]

    assert {:ok, meta} = Client.parse_flags_response(lines)
    assert meta[10].flags == ["\\Seen", "\\Answered"]
    assert meta[10].received_at == ~U[2026-08-06 07:20:33.000000Z]
    assert meta[11].flags == ["\\Flagged"]
    assert meta[11].received_at == ~U[2026-01-01 00:00:00.000000Z]
    assert meta[12].flags == []
    assert meta[12].received_at == nil
  end

  test "parse_internal_date converts IMAP INTERNALDATE to UTC" do
    assert {:ok, ~U[2026-08-06 07:20:33.000000Z]} =
             Client.parse_internal_date("06-Aug-2026 15:20:33 +0800")

    assert {:ok, ~U[2026-08-06 15:20:33.000000Z]} =
             Client.parse_internal_date("\"06-Aug-2026 15:20:33 +0000\"")
  end

  test "seen? detects \\Seen flag case-insensitively" do
    assert Client.seen?(["\\Seen"])
    assert Client.seen?(["\\seen"])
    refute Client.seen?(["\\Flagged"])
    refute Client.seen?([])
  end

  test "store_flags_command builds add and remove STORE commands" do
    assert Client.store_flags_command(10, :add, ["\\Seen"]) ==
             "UID STORE 10 +FLAGS (\\Seen)"

    assert Client.store_flags_command(10, :remove, ["\\Seen"]) ==
             "UID STORE 10 -FLAGS (\\Seen)"
  end

  defp fetch_over_tcp(response) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, packet: :line])
    {:ok, port} = :inet.port(listener)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)

        try do
          {:ok, command} = :gen_tcp.recv(socket, 0, 1_000)
          :ok = :gen_tcp.send(socket, response <> "A1 OK FETCH completed\r\n")
          command
        after
          :gen_tcp.close(socket)
        end
      end)

    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)

    try do
      conn = %Client{socket: {:tcp, socket}, tag_seq: 0, buffer: ""}
      result = Client.uid_fetch_rfc822(conn, 232)
      {result, Task.await(server, 2_000)}
    after
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
      Process.delete({Client, :conn})
    end
  end
end

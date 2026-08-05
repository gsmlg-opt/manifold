defmodule Manifold.Connectors.IMAP.ClientProtocolTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.IMAP.Client

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
end

defmodule Manifold.Connectors.Provider.IMAPTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.IMAP.Fake
  alias Manifold.Connectors.Provider.IMAP

  test "bootstrap page returns messages and advances last_uid" do
    password = "secret"
    raw1 = "Subject: one\r\n\r\nHi\r\n"
    raw2 = "Subject: two\r\n\r\nYo\r\n"

    config = [
      host: "fake",
      port: 993,
      tls_mode: "ssl",
      username: "user@example.com",
      mailbox_path: "INBOX",
      transport: Fake,
      page_size: 1,
      fake: %{
        password_expected: password,
        uidvalidity: 3,
        messages: [{1, raw1}, {2, raw2}]
      }
    ]

    assert {:ok, [cursor]} = IMAP.initial_cursors(password, config, [])
    assert cursor.scope == "INBOX"
    assert cursor.phase == "bootstrap"

    assert {:ok, page} = IMAP.sync_page(password, cursor, config, [])
    assert length(page.messages) == 1
    assert hd(page.messages).id == "imap:3:1"
    assert page.cursor.metadata["last_uid"] == 1
    assert page.cursor.phase == "bootstrap"

    assert {:ok, page2} = IMAP.sync_page(password, page.cursor, config, [])
    assert length(page2.messages) == 1
    assert hd(page2.messages).id == "imap:3:2"
    assert page2.cursor.metadata["last_uid"] == 2
    assert page2.cursor.phase == "incremental"
  end

  test "fetch_raw returns rfc822 bytes" do
    password = "secret"
    raw = "Subject: one\r\n\r\nHi\r\n"

    config = [
      host: "fake",
      port: 993,
      tls_mode: "ssl",
      username: "user@example.com",
      mailbox_path: "INBOX",
      transport: Fake,
      fake: %{
        password_expected: password,
        uidvalidity: 3,
        messages: [{1, raw}]
      }
    ]

    assert {:ok, %{bytes: ^raw, folder_kind: "inbox"}} =
             IMAP.fetch_raw(password, "imap:3:1", config, [])
  end
end

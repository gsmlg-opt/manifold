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
        messages: [{1, raw1, ["\\Seen"]}, {2, raw2}]
      }
    ]

    assert {:ok, [cursor]} = IMAP.initial_cursors(password, config, [])
    assert cursor.scope == "INBOX"
    assert cursor.phase == "bootstrap"

    # UNSEEN uid 2 is beyond the next sequential page, so it is boosted first.
    assert {:ok, page} = IMAP.sync_page(password, cursor, config, [])
    assert length(page.messages) == 1
    assert hd(page.messages).id == "imap:3:2"
    assert hd(page.messages).read? == false
    assert page.cursor.metadata["last_uid"] == 0
    assert page.cursor.metadata["boosted_until"] == 2
    assert page.cursor.phase == "bootstrap"
    assert page.cursor.page_cursor

    assert {:ok, page2} = IMAP.sync_page(password, page.cursor, config, [])
    assert length(page2.messages) == 1
    assert hd(page2.messages).id == "imap:3:1"
    assert hd(page2.messages).read? == true
    assert page2.cursor.metadata["last_uid"] == 1
    assert page2.cursor.phase == "bootstrap"

    assert {:ok, page3} = IMAP.sync_page(password, page2.cursor, config, [])
    assert length(page3.messages) == 1
    assert hd(page3.messages).id == "imap:3:2"
    assert page3.cursor.metadata["last_uid"] == 2
    assert page3.cursor.phase == "incremental"
  end

  test "bootstrap prefers FLAGS repair for already-imported uids before new uids" do
    password = "secret"
    raw1 = "Subject: one\r\n\r\nHi\r\n"
    raw2 = "Subject: two\r\n\r\nYo\r\n"
    raw3 = "Subject: three\r\n\r\nHey\r\n"

    config = [
      host: "fake",
      port: 993,
      tls_mode: "ssl",
      username: "user@example.com",
      mailbox_path: "INBOX",
      transport: Fake,
      page_size: 10,
      fake: %{
        password_expected: password,
        uidvalidity: 3,
        messages: [{1, raw1, ["\\Seen"]}, {2, raw2, ["\\Seen"]}, {3, raw3}]
      }
    ]

    cursor = %Manifold.Connectors.Provider.SyncCursor{
      scope: "INBOX",
      phase: "bootstrap",
      page_cursor: "new:2",
      metadata: %{"uidvalidity" => 3, "last_uid" => 2, "flags_scan_uid" => 0}
    }

    assert {:ok, page} = IMAP.sync_page(password, cursor, config, [])
    assert Enum.map(page.messages, & &1.id) == ["imap:3:1", "imap:3:2"]
    assert Enum.all?(page.messages, & &1.read?)
    assert page.cursor.metadata["last_uid"] == 2
    assert page.cursor.metadata["flags_scan_uid"] == 2
    assert page.cursor.page_cursor

    assert {:ok, page2} = IMAP.sync_page(password, page.cursor, config, [])
    assert Enum.map(page2.messages, & &1.id) == ["imap:3:3"]
    refute hd(page2.messages).read?
    assert page2.cursor.metadata["last_uid"] == 3
    assert page2.cursor.metadata["flags_scan_uid"] == 3
  end

  test "bootstrap boosts UNSEEN uids beyond the next sequential page" do
    password = "secret"

    config = [
      host: "fake",
      port: 993,
      tls_mode: "ssl",
      username: "user@example.com",
      mailbox_path: "INBOX",
      transport: Fake,
      page_size: 2,
      fake: %{
        password_expected: password,
        uidvalidity: 3,
        messages: [
          {1, "Subject: old1\r\n\r\n", ["\\Seen"]},
          {2, "Subject: old2\r\n\r\n", ["\\Seen"]},
          {3, "Subject: old3\r\n\r\n", ["\\Seen"]},
          {10, "Subject: unread\r\n\r\n"}
        ]
      }
    ]

    cursor = %Manifold.Connectors.Provider.SyncCursor{
      scope: "INBOX",
      phase: "bootstrap",
      page_cursor: "new:0",
      metadata: %{
        "uidvalidity" => 3,
        "last_uid" => 0,
        "flags_scan_uid" => 0,
        "boosted_until" => 0
      }
    }

    assert {:ok, page} = IMAP.sync_page(password, cursor, config, [])
    assert Enum.map(page.messages, & &1.id) == ["imap:3:10"]
    refute hd(page.messages).read?
    assert page.cursor.metadata["last_uid"] == 0
    assert page.cursor.metadata["boosted_until"] == 10
    assert page.cursor.page_cursor == "boost:10"

    assert {:ok, page2} = IMAP.sync_page(password, page.cursor, config, [])
    # After UNSEEN boost, a large gap prefers newest-first beyond the next history page.
    assert Enum.map(page2.messages, & &1.id) == ["imap:3:3"]
    assert page2.cursor.metadata["last_uid"] == 0
    assert page2.cursor.metadata["recent_until"] == 3
    assert page2.cursor.page_cursor == "recent:3"
  end

  test "bootstrap imports newest uids first when history watermark lags" do
    password = "secret"

    messages =
      for uid <- 1..10 do
        {uid, "Subject: m#{uid}\r\n\r\n", ["\\Seen"]}
      end

    config = [
      host: "fake",
      port: 993,
      tls_mode: "ssl",
      username: "user@example.com",
      mailbox_path: "INBOX",
      transport: Fake,
      page_size: 2,
      fake: %{
        password_expected: password,
        uidvalidity: 3,
        messages: messages
      }
    ]

    cursor = %Manifold.Connectors.Provider.SyncCursor{
      scope: "INBOX",
      phase: "bootstrap",
      page_cursor: "new:0",
      metadata: %{
        "uidvalidity" => 3,
        "last_uid" => 0,
        "flags_scan_uid" => 0,
        "boosted_until" => 0
      }
    }

    assert {:ok, page} = IMAP.sync_page(password, cursor, config, [])
    assert Enum.map(page.messages, & &1.id) == ["imap:3:9", "imap:3:10"]
    assert page.cursor.metadata["last_uid"] == 0
    assert page.cursor.metadata["recent_until"] == 9
    assert page.cursor.page_cursor == "recent:9"

    assert {:ok, page2} = IMAP.sync_page(password, page.cursor, config, [])
    assert Enum.map(page2.messages, & &1.id) == ["imap:3:7", "imap:3:8"]
    assert page2.cursor.metadata["recent_until"] == 7
  end

  test "incremental sync refreshes read flags for existing uids" do
    password = "secret"
    raw = "Subject: one\r\n\r\nHi\r\n"

    config = [
      host: "fake",
      port: 993,
      tls_mode: "ssl",
      username: "user@example.com",
      mailbox_path: "INBOX",
      transport: Fake,
      page_size: 10,
      fake: %{
        password_expected: password,
        uidvalidity: 3,
        messages: [{1, raw, ["\\Seen"]}]
      }
    ]

    cursor = %Manifold.Connectors.Provider.SyncCursor{
      scope: "INBOX",
      phase: "incremental",
      metadata: %{"uidvalidity" => 3, "last_uid" => 1, "flags_scan_uid" => 0}
    }

    assert {:ok, page} = IMAP.sync_page(password, cursor, config, [])
    assert length(page.messages) == 1
    assert hd(page.messages).id == "imap:3:1"
    assert hd(page.messages).read? == true
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
        messages: [{1, raw, ["\\Seen"]}]
      }
    ]

    assert {:ok, %{bytes: ^raw, folder_kind: "inbox", read?: true}} =
             IMAP.fetch_raw(password, "imap:3:1", config, [])
  end

  test "set_read stores \\Seen flag on the server" do
    password = "secret"
    raw = "Subject: one\r\n\r\nHi\r\n"
    {:ok, stores} = Agent.start_link(fn -> [] end)

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
        messages: [{1, raw}],
        store_log: stores
      }
    ]

    assert :ok = IMAP.set_read(password, "imap:3:1", true, config)
    assert :ok = IMAP.set_read(password, "imap:3:1", false, config)

    assert Agent.get(stores, & &1) == [
             {1, :remove, ["\\Seen"]},
             {1, :add, ["\\Seen"]}
           ]
  end

  test "retain_session reuses one connection for sync_page and fetch_raw" do
    password = "secret"
    raw1 = "Subject: one\r\n\r\nHi\r\n"
    raw2 = "Subject: two\r\n\r\nYo\r\n"
    {:ok, connect_count} = Agent.start_link(fn -> 0 end)

    config = [
      host: "fake",
      port: 993,
      tls_mode: "ssl",
      username: "user@example.com",
      mailbox_path: "INBOX",
      transport: Fake,
      page_size: 10,
      fake: %{
        password_expected: password,
        uidvalidity: 3,
        messages: [{1, raw1}, {2, raw2}],
        connect_count: connect_count
      }
    ]

    assert {:ok, [cursor]} = IMAP.initial_cursors(password, config, [])

    assert {:ok, page} = IMAP.sync_page(password, cursor, config, retain_session: true)
    assert length(page.messages) == 2
    assert Agent.get(connect_count, & &1) == 1

    assert {:ok, %{bytes: ^raw1}} = IMAP.fetch_raw(password, "imap:3:1", config, [])
    assert {:ok, %{bytes: ^raw2}} = IMAP.fetch_raw(password, "imap:3:2", config, [])
    assert Agent.get(connect_count, & &1) == 1

    assert :ok = IMAP.release_session()
    assert Agent.get(connect_count, & &1) == 1
  after
    IMAP.release_session()
  end

  test "standalone fetch_raw still connects when no retained session" do
    password = "secret"
    raw = "Subject: one\r\n\r\nHi\r\n"
    {:ok, connect_count} = Agent.start_link(fn -> 0 end)

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
        messages: [{1, raw}],
        connect_count: connect_count
      }
    ]

    assert {:ok, _} = IMAP.fetch_raw(password, "imap:3:1", config, [])
    assert Agent.get(connect_count, & &1) == 1
  end

  test "sync_page and fetch_raw surface INTERNALDATE as received_at" do
    password = "secret"
    raw = "Subject: one\r\n\r\nHi\r\n"
    received_at = ~U[2026-08-06 07:20:33.000000Z]

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
        messages: [{1, raw, ["\\Seen"], received_at}]
      }
    ]

    assert {:ok, [cursor]} = IMAP.initial_cursors(password, config, [])
    assert {:ok, page} = IMAP.sync_page(password, cursor, config, [])
    assert hd(page.messages).received_at == received_at

    assert {:ok, %{received_at: ^received_at}} =
             IMAP.fetch_raw(password, "imap:3:1", config, [])
  end
end

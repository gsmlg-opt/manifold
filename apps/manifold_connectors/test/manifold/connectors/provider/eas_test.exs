defmodule Manifold.Connectors.Provider.EASTest do
  use ExUnit.Case, async: false

  alias Manifold.Connectors.EAS.Fake
  alias Manifold.Connectors.Provider.EAS
  alias Manifold.Connectors.Provider.{Page, RawMessage}

  setup do
    raw = "From: a@example.com\r\nTo: b@example.com\r\nSubject: hi\r\n\r\nBody\r\n"

    config = [
      host: "mail.example",
      port: 443,
      path: "/Microsoft-Server-ActiveSync",
      username: "user@example.com",
      email_address: "user@example.com",
      device_id: "abc123def4567890",
      device_type: "iPhone",
      protocol_version: "14.1",
      policy_key: "12345",
      collection_id: "1",
      transport: Fake,
      fake: %{
        password_expected: "secret",
        messages: [{10, raw}, {11, raw}]
      }
    ]

    {:ok, config: config, raw: raw}
  end

  test "sync_page enumerates ServerIds after SyncKey handshake", %{config: config} do
    {:ok, [cursor]} = EAS.initial_cursors("secret", config, [])

    assert {:ok, %Page{messages: messages, cursor: next}} =
             EAS.sync_page("secret", cursor, config, [])

    assert Enum.map(messages, & &1.id) == ["1:10", "1:11"]
    assert next.metadata["sync_key"] != "0"
    assert next.phase == "incremental"
  end

  test "fetch_raw returns MIME bytes", %{config: config, raw: raw} do
    assert {:ok, %RawMessage{bytes: ^raw, folder_kind: "inbox"}} =
             EAS.fetch_raw("secret", "1:10", config, [])
  end

  test "retain_session reuses connection for fetch_raw", %{config: config, raw: raw} do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    config =
      Keyword.merge(config,
        fake:
          Map.merge(Keyword.fetch!(config, :fake), %{
            connect_count: counter,
            messages: [{10, raw}]
          })
      )

    {:ok, [cursor]} = EAS.initial_cursors("secret", config, [])

    assert {:ok, %Page{messages: [%{id: "1:10"}]}} =
             EAS.sync_page("secret", cursor, config, retain_session: true)

    assert {:ok, %RawMessage{bytes: ^raw}} = EAS.fetch_raw("secret", "1:10", config, [])
    assert Agent.get(counter, & &1) == 1
    assert :ok = EAS.release_session()
  end

  test "sync_page imports Read flags from Adds", %{config: config, raw: raw} do
    config =
      Keyword.merge(config,
        fake: %{
          password_expected: "secret",
          messages: [{10, raw, %{read?: true}}]
        }
      )

    {:ok, [cursor]} = EAS.initial_cursors("secret", config, [])

    assert {:ok, %Page{messages: [message]}} = EAS.sync_page("secret", cursor, config, [])
    assert message.id == "1:10"
    assert message.read?
  end

  test "sync_page imports DateReceived as received_at", %{config: config, raw: raw} do
    received_at = ~U[2026-08-06 07:20:33.000000Z]

    config =
      Keyword.merge(config,
        fake: %{
          password_expected: "secret",
          messages: [{10, raw, %{read?: false, received_at: received_at}}]
        }
      )

    {:ok, [cursor]} = EAS.initial_cursors("secret", config, [])

    assert {:ok, %Page{messages: [message]}} = EAS.sync_page("secret", cursor, config, [])
    assert message.received_at == received_at
  end

  test "set_read writes Change via transport", %{config: config, raw: raw} do
    {:ok, changes} = Agent.start_link(fn -> [] end)

    config =
      Keyword.merge(config,
        sync_key: "3",
        fake: %{
          password_expected: "secret",
          messages: [{10, raw}],
          change_log: changes
        }
      )

    assert :ok = EAS.set_read("secret", "1:10", true, config)
    assert :ok = EAS.set_read("secret", "1:10", false, config)
    assert Agent.get(changes, & &1) == [{"10", false}, {"10", true}]
  end
end

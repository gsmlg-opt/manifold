defmodule Manifold.Connectors.SyncImapTest do
  use Manifold.DataCase, async: false

  alias Manifold.Connectors
  alias Manifold.Connectors.IMAP.Fake
  alias Manifold.Connectors.Schema.RemoteMessage
  alias Manifold.Ingest.Schema.InboundDelivery
  alias Manifold.Mail.Schema.MailboxEntry
  alias Manifold.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_transport = Application.get_env(:manifold_connectors, :imap_transport)
    old_fake = Application.get_env(:manifold_connectors, :imap_fake)
    old_spool = Application.fetch_env!(:manifold_storage, :spool_dir)
    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :imap_transport, Fake)
    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))

    raw =
      "From: sender@example.net\r\nTo: reader@imap-sync.example\r\nSubject: hello imap\r\n\r\nBody\r\n"

    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      uidvalidity: 7,
      messages: [{1, raw}]
    })

    on_exit(fn ->
      restore_env(:manifold_connectors, :encryption_key, old_key)
      restore_env(:manifold_connectors, :imap_transport, old_transport)
      restore_env(:manifold_connectors, :imap_fake, old_fake)
      Application.put_env(:manifold_storage, :spool_dir, old_spool)
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
    end)

    assert {:ok, account} =
             Connectors.create_imap_account(%{
               email_address: "reader@imap-sync.example",
               username: "reader@imap-sync.example",
               password: "secret",
               host: "imap.example",
               port: 993,
               tls_mode: "ssl"
             })

    {:ok, account: account, raw: raw}
  end

  test "sync_account imports IMAP INBOX messages via provider_import", %{account: account} do
    assert {:snooze, 1} = Connectors.sync_account(account.id)

    mapping =
      Repo.get_by!(RemoteMessage,
        external_account_id: account.id,
        provider_message_id: "imap:7:1"
      )

    assert mapping.state == "imported"
    assert mapping.remote_folder_kind == "inbox"

    delivery = Repo.get!(InboundDelivery, mapping.inbound_delivery_id)
    assert delivery.source_kind == "provider_import"

    assert Repo.get_by!(MailboxEntry, inbound_delivery_id: mapping.inbound_delivery_id).mailbox_id ==
             account.account_id

    assert :ok = Connectors.sync_account(account.id)
  end

  defp restore_env(_app, _key, nil), do: :ok
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end

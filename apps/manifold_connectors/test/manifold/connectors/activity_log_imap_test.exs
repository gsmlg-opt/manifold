defmodule Manifold.Connectors.ActivityLogImapTest do
  use Manifold.DataCase, async: false

  alias Manifold.Connectors
  alias Manifold.Connectors.ActivityLog
  alias Manifold.Connectors.ActivityLog.Handler
  alias Manifold.Connectors.IMAP.Fake

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    log_dir = Path.join(tmp_dir, "connectors")
    old = snapshot_env()

    Application.put_env(:manifold_connectors, :activity_log_dir, log_dir)
    Application.put_env(:manifold_connectors, :activity_log_retention_days, 14)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :imap_transport, Fake)
    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))

    Handler.detach()
    assert :ok = Handler.attach()

    on_exit(fn ->
      Handler.detach()
      restore_env(old)
    end)

    :ok
  end

  test "successful sync writes sync stop entry with counts" do
    raw =
      "From: sender@example.net\r\nTo: reader@imap-act.example\r\nSubject: hi\r\n\r\nBody\r\n"

    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      uidvalidity: 3,
      messages: [{1, raw}]
    })

    assert {:ok, account} =
             Connectors.create_imap_account(%{
               email_address: "reader@imap-act.example",
               username: "reader@imap-act.example",
               password: "secret",
               host: "imap.example",
               port: 993,
               tls_mode: "ssl"
             })

    assert {:snooze, 1} = Connectors.sync_account(account.id)

    assert {:ok, entries} = ActivityLog.read(account.id, Date.utc_today(), 200)

    sync_entries =
      Enum.filter(entries, &(&1["event"] == ["manifold", "connectors", "sync", "stop"]))

    assert [%{"measurements" => measurements, "metadata" => meta} | _] = sync_entries
    assert measurements["message_count"] >= 1
    assert measurements["page_count"] == 1
    assert meta["result"] == "ok"
    assert meta["account_id"] == account.id
    assert meta["provider"] == "imap"

    assert Enum.any?(
             entries,
             &(&1["event"] == ["manifold", "connectors", "imap", "auth", "stop"])
           )
  end

  test "auth failure after account exists writes failure summary entry" do
    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      uidvalidity: 1,
      messages: []
    })

    assert {:ok, account} =
             Connectors.create_imap_account(%{
               email_address: "reader@imap-fail-act.example",
               username: "reader@imap-fail-act.example",
               password: "secret",
               host: "imap.example",
               port: 993,
               tls_mode: "ssl"
             })

    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "other",
      uidvalidity: 1,
      messages: []
    })

    assert {:cancel, :reconnect_required} = Connectors.sync_account(account.id)

    assert {:ok, entries} = ActivityLog.read(account.id, Date.utc_today(), 200)

    assert Enum.any?(entries, fn e ->
             e["event"] == ["manifold", "connectors", "imap", "auth", "stop"] and
               e["metadata"]["result"] == "error" and
               e["metadata"]["error_code"] == "auth_failed"
           end)

    assert Enum.any?(entries, fn e ->
             e["event"] == ["manifold", "connectors", "sync", "stop"] and
               e["metadata"]["result"] == "error"
           end)
  end

  defp snapshot_env do
    %{
      activity_log_dir: Application.get_env(:manifold_connectors, :activity_log_dir),
      activity_log_retention_days:
        Application.get_env(:manifold_connectors, :activity_log_retention_days),
      encryption_key: Application.get_env(:manifold_connectors, :encryption_key),
      imap_transport: Application.get_env(:manifold_connectors, :imap_transport),
      imap_fake: Application.get_env(:manifold_connectors, :imap_fake),
      spool_dir: Application.get_env(:manifold_storage, :spool_dir),
      raw_store_dir: Application.get_env(:manifold_storage, :raw_store_dir)
    }
  end

  defp restore_env(old) do
    Enum.each(
      [
        {:manifold_connectors, :activity_log_dir, old.activity_log_dir},
        {:manifold_connectors, :activity_log_retention_days, old.activity_log_retention_days},
        {:manifold_connectors, :encryption_key, old.encryption_key},
        {:manifold_connectors, :imap_transport, old.imap_transport},
        {:manifold_connectors, :imap_fake, old.imap_fake},
        {:manifold_storage, :spool_dir, old.spool_dir},
        {:manifold_storage, :raw_store_dir, old.raw_store_dir}
      ],
      fn {app, key, value} ->
        if is_nil(value), do: :ok, else: Application.put_env(app, key, value)
      end
    )
  end
end

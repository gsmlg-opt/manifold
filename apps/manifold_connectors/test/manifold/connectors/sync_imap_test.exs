defmodule Manifold.Connectors.SyncImapTest do
  use Manifold.DataCase, async: false

  alias Manifold.Connectors
  alias Manifold.Connectors.IMAP.Fake
  alias Manifold.Connectors.Jobs.ApplyRemoteState
  alias Manifold.Connectors.Schema.RemoteMessage
  alias Manifold.Ingest
  alias Manifold.Ingest.Schema.InboundDelivery
  alias Manifold.Mail.Schema.MailboxEntry
  alias Manifold.Repo

  import Ecto.Query

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_transport = Application.get_env(:manifold_connectors, :imap_transport)
    old_fake = Application.get_env(:manifold_connectors, :imap_fake)
    old_spool = Application.fetch_env!(:manifold_storage, :spool_dir)
    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)

    Manifold.Connectors.ReadPush.Handler.attach()

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
      messages: [{1, raw, ["\\Seen"]}]
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
    assert mapping.remote_read == true

    delivery = Repo.get!(InboundDelivery, mapping.inbound_delivery_id)
    assert delivery.source_kind == "provider_import"

    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: mapping.inbound_delivery_id)
    assert entry.mailbox_id == account.account_id

    assert :ok = Ingest.archive_delivery(mapping.inbound_delivery_id)
    assert :ok = Ingest.project_delivery(mapping.inbound_delivery_id)
    drain_remote_state_jobs()

    entry = Repo.get!(MailboxEntry, entry.id)
    assert entry.read_at

    assert :ok = Connectors.sync_account(account.id)
  end

  test "incremental IMAP sync updates read status when FLAGS change", %{
    account: account,
    raw: raw
  } do
    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      uidvalidity: 7,
      messages: [{1, raw}]
    })

    assert {:snooze, 1} = Connectors.sync_account(account.id)

    mapping =
      Repo.get_by!(RemoteMessage,
        external_account_id: account.id,
        provider_message_id: "imap:7:1"
      )

    refute mapping.remote_read

    assert :ok = Ingest.archive_delivery(mapping.inbound_delivery_id)
    assert :ok = Ingest.project_delivery(mapping.inbound_delivery_id)
    drain_remote_state_jobs()

    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: mapping.inbound_delivery_id)
    assert is_nil(entry.read_at)

    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      uidvalidity: 7,
      messages: [{1, raw, ["\\Seen"]}]
    })

    # First idle page arms FLAGS scan; second page applies updated FLAGS.
    assert :ok = Connectors.sync_account(account.id)
    assert :ok = Connectors.sync_account(account.id)
    drain_remote_state_jobs()

    mapping = Repo.get!(RemoteMessage, mapping.id)
    assert mapping.remote_read == true

    entry = Repo.get!(MailboxEntry, entry.id)
    assert entry.read_at
  end

  test "local mark_read pushes \\Seen back to IMAP", %{account: account, raw: raw} do
    alias Manifold.Connectors.Jobs.PushRemoteRead
    alias Manifold.Mail

    {:ok, stores} = Agent.start_link(fn -> [] end)

    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      uidvalidity: 7,
      messages: [{1, raw}],
      store_log: stores
    })

    assert {:snooze, 1} = Connectors.sync_account(account.id)

    mapping =
      Repo.get_by!(RemoteMessage,
        external_account_id: account.id,
        provider_message_id: "imap:7:1"
      )

    assert :ok = Ingest.archive_delivery(mapping.inbound_delivery_id)
    assert :ok = Ingest.project_delivery(mapping.inbound_delivery_id)
    drain_remote_state_jobs()

    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: mapping.inbound_delivery_id)
    assert entry.mailbox_id == account.account_id
    assert {:ok, _} = Mail.set_delivery_quarantine(mapping.inbound_delivery_id, false)
    entry = Repo.get!(MailboxEntry, entry.id)
    refute entry.quarantined
    assert is_nil(entry.read_at)

    assert {:ok, 1} = Mail.mark_read(entry.mailbox_id, [entry.id], true)
    assert :ok = drain_push_read_jobs()

    assert Agent.get(stores, & &1) == [{1, :add, ["\\Seen"]}]
    assert Repo.get!(RemoteMessage, mapping.id).remote_read == true

    assert {:ok, 1} = Mail.mark_read(entry.mailbox_id, [entry.id], false)
    assert :ok = drain_push_read_jobs()

    assert Agent.get(stores, & &1) == [{1, :remove, ["\\Seen"]}, {1, :add, ["\\Seen"]}]
    refute Repo.get!(RemoteMessage, mapping.id).remote_read
  end

  defp drain_remote_state_jobs do
    Oban.Job
    |> where([job], job.worker == ^inspect(ApplyRemoteState))
    |> where([job], job.state in ["available", "scheduled", "retryable"])
    |> Repo.all()
    |> Enum.each(fn job ->
      assert :ok = ApplyRemoteState.perform(job)
    end)
  end

  defp drain_push_read_jobs do
    alias Manifold.Connectors.Jobs.PushRemoteRead

    jobs =
      Oban.Job
      |> where([job], job.worker == ^inspect(PushRemoteRead))
      |> where([job], job.state in ["available", "scheduled", "retryable"])
      |> order_by([job], asc: job.id)
      |> Repo.all()

    assert jobs != []

    Enum.each(jobs, fn job ->
      assert :ok = PushRemoteRead.perform(job)

      job
      |> Ecto.Changeset.change(%{state: "completed", completed_at: DateTime.utc_now()})
      |> Repo.update!()
    end)

    :ok
  end

  defp restore_env(_app, _key, nil), do: :ok
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end

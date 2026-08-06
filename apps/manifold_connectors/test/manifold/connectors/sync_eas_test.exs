defmodule Manifold.Connectors.SyncEasTest do
  use Manifold.DataCase, async: false

  import Ecto.Query

  alias Manifold.Connectors
  alias Manifold.Connectors.EAS.Fake
  alias Manifold.Connectors.Jobs.{ApplyRemoteState, PushRemoteRead}
  alias Manifold.Connectors.Schema.RemoteMessage
  alias Manifold.Ingest
  alias Manifold.Ingest.Schema.InboundDelivery
  alias Manifold.Mail
  alias Manifold.Mail.Schema.MailboxEntry
  alias Manifold.Repo

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_transport = Application.get_env(:manifold_connectors, :eas_transport)
    old_fake = Application.get_env(:manifold_connectors, :eas_fake)
    old_spool = Application.fetch_env!(:manifold_storage, :spool_dir)
    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)

    Manifold.Connectors.ReadPush.Handler.attach()

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :eas_transport, Fake)
    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))

    raw =
      "From: sender@example.net\r\nTo: reader@eas-sync.example\r\nSubject: hello eas\r\n\r\nBody\r\n"

    Application.put_env(:manifold_connectors, :eas_fake, %{
      password_expected: "secret",
      messages: [{1, raw}]
    })

    on_exit(fn ->
      restore_env(:manifold_connectors, :encryption_key, old_key)
      restore_env(:manifold_connectors, :eas_transport, old_transport)
      restore_env(:manifold_connectors, :eas_fake, old_fake)
      Application.put_env(:manifold_storage, :spool_dir, old_spool)
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
    end)

    assert {:ok, account} =
             Connectors.create_eas_account(%{
               email_address: "reader@eas-sync.example",
               username: "reader@eas-sync.example",
               password: "secret",
               host: "mail.example",
               port: 443
             })

    {:ok, account: account, raw: raw}
  end

  test "sync_account imports EAS Inbox messages via provider_import", %{account: account} do
    assert {:snooze, 1} = Connectors.sync_account(account.id)

    mapping =
      Repo.get_by!(RemoteMessage,
        external_account_id: account.id,
        provider_message_id: "1:1"
      )

    assert mapping.state == "imported"
    assert mapping.remote_folder_kind == "inbox"

    delivery = Repo.get!(InboundDelivery, mapping.inbound_delivery_id)
    assert delivery.source_kind == "provider_import"

    assert Repo.get_by!(MailboxEntry, inbound_delivery_id: mapping.inbound_delivery_id).mailbox_id ==
             account.account_id

    assert :ok = Connectors.sync_account(account.id)
  end

  test "sync imports Read flag into remote_read and mailbox entry", %{
    account: account,
    raw: raw
  } do
    Application.put_env(:manifold_connectors, :eas_fake, %{
      password_expected: "secret",
      messages: [{1, raw, %{read?: true}}]
    })

    assert {:snooze, 1} = Connectors.sync_account(account.id)

    mapping =
      Repo.get_by!(RemoteMessage,
        external_account_id: account.id,
        provider_message_id: "1:1"
      )

    assert mapping.remote_read

    assert :ok = Ingest.archive_delivery(mapping.inbound_delivery_id)
    assert :ok = Ingest.project_delivery(mapping.inbound_delivery_id)
    drain_remote_state_jobs()

    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: mapping.inbound_delivery_id)
    assert entry.read_at
  end

  test "incremental sync applies Read changes from Exchange", %{account: account, raw: raw} do
    assert {:snooze, 1} = Connectors.sync_account(account.id)

    mapping =
      Repo.get_by!(RemoteMessage,
        external_account_id: account.id,
        provider_message_id: "1:1"
      )

    refute mapping.remote_read

    assert :ok = Ingest.archive_delivery(mapping.inbound_delivery_id)
    assert :ok = Ingest.project_delivery(mapping.inbound_delivery_id)
    drain_remote_state_jobs()

    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: mapping.inbound_delivery_id)
    assert is_nil(entry.read_at)

    Application.put_env(:manifold_connectors, :eas_fake, %{
      password_expected: "secret",
      messages: [{1, raw}],
      last_synced_id: 1,
      pending_changes: [{1, true}]
    })

    assert :ok = Connectors.sync_account(account.id)
    drain_remote_state_jobs()

    mapping = Repo.get!(RemoteMessage, mapping.id)
    assert mapping.remote_read

    entry = Repo.get!(MailboxEntry, entry.id)
    assert entry.read_at
  end

  test "local mark_read pushes Read Change back to EAS", %{account: account, raw: raw} do
    {:ok, changes} = Agent.start_link(fn -> [] end)

    Application.put_env(:manifold_connectors, :eas_fake, %{
      password_expected: "secret",
      messages: [{1, raw}],
      change_log: changes
    })

    assert {:snooze, 1} = Connectors.sync_account(account.id)

    mapping =
      Repo.get_by!(RemoteMessage,
        external_account_id: account.id,
        provider_message_id: "1:1"
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

    assert Agent.get(changes, & &1) == [{"1", true}]
    assert Repo.get!(RemoteMessage, mapping.id).remote_read == true

    assert {:ok, 1} = Mail.mark_read(entry.mailbox_id, [entry.id], false)
    assert :ok = drain_push_read_jobs()

    assert Agent.get(changes, & &1) == [{"1", false}, {"1", true}]
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
    Oban.Job
    |> where([job], job.worker == ^inspect(PushRemoteRead))
    |> where([job], job.state in ["available", "scheduled", "retryable"])
    |> Repo.all()
    |> Enum.each(fn job ->
      assert :ok = PushRemoteRead.perform(job)
    end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end

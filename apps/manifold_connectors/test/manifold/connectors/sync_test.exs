defmodule Manifold.Connectors.SyncTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.Jobs.ApplyRemoteState
  alias Manifold.Connectors.OAuth.Consumed

  alias Manifold.Connectors.Provider.{
    Error,
    Identity,
    Page,
    RawMessage,
    Token
  }

  alias Manifold.Connectors.Provider.RemoteMessage, as: ProviderRemoteMessage
  alias Manifold.Connectors.Provider.SyncCursor, as: ProviderCursor

  alias Manifold.Connectors.Schema.{
    Credential,
    ReceiveMethod,
    RemoteMessage,
    SyncCursor
  }

  alias Manifold.Ingest.Schema.{DeliveryRecipient, InboundDelivery}
  alias Manifold.Ingest
  alias Manifold.Mail.Schema.{MailboxEntry, Message}
  alias Manifold.Repo

  @moduletag :tmp_dir

  defmodule FakeProvider do
    @behaviour Manifold.Connectors.Provider

    @impl true
    def exchange_code("valid-code", "verifier", _redirect_uri, _config, opts) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      {:ok,
       %Token{
         access_token: "initial-access",
         refresh_token: "initial-refresh",
         expires_at: DateTime.add(now, 3_600, :second),
         scopes: ["openid", "email", "https://www.googleapis.com/auth/gmail.readonly"]
       }}
    end

    @impl true
    def refresh_token("initial-refresh", _config, opts) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      {:ok,
       %Token{
         access_token: "refreshed-access",
         refresh_token: "rotated-refresh",
         expires_at: DateTime.add(now, 3_600, :second),
         scopes: ["https://www.googleapis.com/auth/gmail.readonly"]
       }}
    end

    @impl true
    def identity("initial-access", _config, _opts) do
      {:ok, %Identity{id: "sync-account", email_address: "person@gmail.example"}}
    end

    @impl true
    def initial_cursors("initial-access", _config, _opts) do
      {:ok, [%ProviderCursor{scope: "mailbox", phase: "initial", bootstrap_cursor: "100"}]}
    end

    @impl true
    def sync_page(access_token, cursor, _config, _opts) do
      send(self(), {:sync_access_token, access_token})

      case Process.get(:sync_page_result) do
        nil ->
          {:ok,
           %Page{
             cursor: %{cursor | phase: "incremental", committed_cursor: "101"}
           }}

        result ->
          result
      end
    end

    @impl true
    def fetch_raw(access_token, message_id, _config, _opts) do
      send(self(), {:raw_access_token, access_token, message_id})

      case Process.get({:raw_result, message_id}) do
        nil ->
          {:ok,
           %RawMessage{
             bytes: "From: sender@example.net\r\nSubject: #{message_id}\r\n\r\nBody\r\n",
             received_at: ~U[2026-07-29 01:00:00.000000Z],
             thread_id: "thread-" <> message_id,
             labels: ["INBOX", "STARRED"],
             read?: false,
             starred?: true
           }}

        result ->
          result
      end
    end
  end

  setup %{tmp_dir: tmp_dir} do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_adapters = Application.get_env(:manifold_connectors, :adapters)
    old_providers = Application.get_env(:manifold_connectors, :providers)
    old_spool = Application.fetch_env!(:manifold_storage, :spool_dir)
    old_raw = Application.fetch_env!(:manifold_storage, :raw_store_dir)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :adapters, gmail: FakeProvider)
    Application.put_env(:manifold_connectors, :providers, gmail: [client_id: "client"])
    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))

    on_exit(fn ->
      restore_env(:manifold_connectors, :encryption_key, old_key)
      restore_env(:manifold_connectors, :adapters, old_adapters)
      restore_env(:manifold_connectors, :providers, old_providers)
      Application.put_env(:manifold_storage, :spool_dir, old_spool)
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
      Process.delete(:sync_page_result)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "sync#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "person"})

    assert {:ok, account} =
             Connectors.complete_authorization(
               "gmail",
               "valid-code",
               %Consumed{
                 provider: "gmail",
                 mailbox_id: mailbox.id,
                 redirect_uri: "https://mail.example.test/connectors/gmail/callback",
                 pkce_verifier: "verifier"
               },
               now: DateTime.utc_now(),
               provider_opts: [now: DateTime.utc_now()]
             )

    cursor = Repo.get_by!(SyncCursor, external_account_id: account.id)

    cursor =
      cursor
      |> SyncCursor.changeset(%{
        phase: "incremental",
        bootstrap_cursor: nil,
        committed_cursor: "100"
      })
      |> Repo.update!()

    {:ok, account: account, cursor: cursor, domain: domain, mailbox: mailbox}
  end

  test "imports raw mail before advancing the provider cursor", %{
    account: account,
    cursor: cursor,
    mailbox: mailbox
  } do
    remote = remote_message("message-1")

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [remote],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)

    assert_receive {:raw_access_token, "initial-access", "message-1"}

    mapping =
      Repo.get_by!(RemoteMessage,
        external_account_id: account.id,
        provider_message_id: "message-1"
      )

    assert mapping.state == "imported"
    assert mapping.remote_folder_kind == "inbox"
    assert mapping.remote_read == false
    assert mapping.remote_starred
    assert is_binary(mapping.inbound_delivery_id)

    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "101"
    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(DeliveryRecipient, :count) == 0

    assert Repo.get_by!(MailboxEntry, inbound_delivery_id: mapping.inbound_delivery_id).mailbox_id ==
             mailbox.id
  end

  test "provider mailbox receive time is applied after projection, not sync now", %{
    account: account,
    cursor: cursor,
    mailbox: mailbox
  } do
    provider_received_at = ~U[2026-07-29 01:00:00.000000Z]
    sent_at = ~U[2026-07-28 20:00:00.000000Z]

    Process.put(
      {:raw_result, "message-received-at"},
      {:ok,
       %RawMessage{
         bytes:
           "From: sender@example.net\r\n" <>
             "Date: Tue, 28 Jul 2026 20:00:00 +0000\r\n" <>
             "Subject: receive-time\r\n\r\nBody\r\n",
         received_at: provider_received_at,
         labels: ["INBOX"],
         read?: false,
         starred?: false
       }}
    )

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [
           %ProviderRemoteMessage{
             id: "message-received-at",
             received_at: provider_received_at,
             folder_kind: "inbox",
             labels: ["INBOX"],
             read?: false,
             starred?: false
           }
         ],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)
    mapping = Repo.get_by!(RemoteMessage, provider_message_id: "message-received-at")
    assert mapping.provider_received_at == provider_received_at

    assert :ok = Ingest.archive_delivery(mapping.inbound_delivery_id)
    assert :ok = Ingest.project_delivery(mapping.inbound_delivery_id)

    job = Repo.get_by!(Oban.Job, worker: inspect(ApplyRemoteState))
    assert :ok = ApplyRemoteState.perform(job)

    message = Repo.get_by!(Message, inbound_delivery_id: mapping.inbound_delivery_id)
    assert message.received_at == provider_received_at
    assert message.sent_at == sent_at

    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: mapping.inbound_delivery_id)
    assert entry.folder_id == Manifold.Mail.Folders.get_system(mailbox.id, "inbox").id
  end

  test "missing provider receive time leaves message.received_at nil so UI uses Date header",
       %{
         account: account,
         cursor: cursor,
         mailbox: mailbox
       } do
    sync_now = ~U[2026-08-06 10:20:00.000000Z]
    sent_at = ~U[2026-08-05 08:00:00.000000Z]

    Process.put(
      {:raw_result, "message-no-provider-time"},
      {:ok,
       %RawMessage{
         bytes:
           "From: sender@example.net\r\n" <>
             "Date: Wed, 05 Aug 2026 08:00:00 +0000\r\n" <>
             "Subject: no-provider-time\r\n\r\nBody\r\n",
         received_at: nil,
         labels: ["INBOX"],
         read?: false,
         starred?: false
       }}
    )

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [
           %ProviderRemoteMessage{
             id: "message-no-provider-time",
             received_at: nil,
             folder_kind: "inbox",
             labels: ["INBOX"],
             read?: false,
             starred?: false
           }
         ],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id, now: sync_now)
    mapping = Repo.get_by!(RemoteMessage, provider_message_id: "message-no-provider-time")
    assert is_nil(mapping.provider_received_at)

    delivery = Repo.get!(InboundDelivery, mapping.inbound_delivery_id)
    assert delivery.received_at == sync_now

    assert :ok = Ingest.archive_delivery(mapping.inbound_delivery_id)
    assert :ok = Ingest.project_delivery(mapping.inbound_delivery_id)

    job = Repo.get_by!(Oban.Job, worker: inspect(ApplyRemoteState))
    assert :ok = ApplyRemoteState.perform(job)

    message = Repo.get_by!(Message, inbound_delivery_id: mapping.inbound_delivery_id)
    assert is_nil(message.received_at)
    assert message.sent_at == sent_at

    entry = Repo.get_by!(MailboxEntry, inbound_delivery_id: mapping.inbound_delivery_id)
    assert entry.folder_id == Manifold.Mail.Folders.get_system(mailbox.id, "inbox").id
  end

  test "sync repairs historical fetch-time placeholders using provider_received_at", %{
    account: account,
    cursor: cursor
  } do
    provider_received_at = ~U[2026-07-29 01:00:00.000000Z]
    fetch_time = ~U[2026-08-06 10:20:00.000000Z]

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [remote_message("message-repair")],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)
    mapping = Repo.get_by!(RemoteMessage, provider_message_id: "message-repair")

    assert :ok = Ingest.archive_delivery(mapping.inbound_delivery_id)
    assert :ok = Ingest.project_delivery(mapping.inbound_delivery_id)

    message = Repo.get_by!(Message, inbound_delivery_id: mapping.inbound_delivery_id)

    message
    |> Message.changeset(%{received_at: fetch_time})
    |> Repo.update!()

    mapping
    |> RemoteMessage.changeset(%{provider_received_at: provider_received_at})
    |> Repo.update!()

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [],
         cursor: %{provider_cursor(Repo.get!(SyncCursor, cursor.id)) | committed_cursor: "102"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)

    assert Repo.get!(Message, message.id).received_at == provider_received_at
  end

  test "acceptance before connector mapping retries without another delivery", %{
    account: account,
    cursor: cursor
  } do
    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [remote_message("message-crash")],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert {:error, %{reason: :after_external_accept_before_mapping}} =
             Connectors.sync_account(account.id,
               fail_at: :after_external_accept_before_mapping
             )

    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(RemoteMessage, :count) == 0
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "100"

    Process.put(
      {:raw_result, "message-crash"},
      {:error,
       %Error{
         class: :permanent,
         code: :not_found,
         message: "provider message no longer exists"
       }}
    )

    assert :ok = Connectors.sync_account(account.id)
    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(RemoteMessage, :count) == 1
    assert Repo.one!(RemoteMessage).inbound_delivery_id
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "101"
  end

  test "failure after mapping but before cursor checkpoint replays idempotently", %{
    account: account,
    cursor: cursor
  } do
    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [remote_message("message-checkpoint")],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert {:error, %{reason: :after_page_before_cursor}} =
             Connectors.sync_account(account.id, fail_at: :after_page_before_cursor)

    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(RemoteMessage, :count) == 1
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "100"

    assert :ok = Connectors.sync_account(account.id)
    assert Repo.aggregate(InboundDelivery, :count) == 1
    assert Repo.aggregate(RemoteMessage, :count) == 1
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "101"
  end

  test "rotated refresh token commits before the provider page", %{
    account: account
  } do
    credential = Repo.get_by!(Credential, external_account_id: account.id)

    credential
    |> Credential.changeset(%{token_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)})
    |> Repo.update!()

    assert :ok = Connectors.sync_account(account.id)
    assert_receive {:sync_access_token, "refreshed-access"}

    updated = Repo.get!(Credential, credential.id)

    assert {:ok, "rotated-refresh"} =
             Crypto.decrypt(
               updated.refresh_token_ciphertext,
               "credential:#{account.id}:refresh"
             )
  end

  test "retry-after leaves the cursor unchanged and snoozes", %{
    account: account,
    cursor: cursor
  } do
    Process.put(
      :sync_page_result,
      {:error,
       %Error{
         class: :temporary,
         code: :rate_limited,
         message: "provider rate limited",
         retry_after_seconds: 45
       }}
    )

    assert {:snooze, 45} = Connectors.sync_account(account.id)
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "100"
    assert Repo.get!(ReceiveMethod, account.id).last_error_code == "rate_limited"
  end

  test "folder discovery tombstones remove obsolete synchronization lanes", %{
    account: account,
    cursor: cursor
  } do
    Repo.insert!(
      SyncCursor.changeset(%SyncCursor{}, %{
        external_account_id: account.id,
        scope: "folder:gone",
        phase: "steady",
        committed_cursor: "https://provider.test/gone",
        metadata: %{"folder_kind" => "archive"},
        last_completed_at: DateTime.utc_now()
      })
    )

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         discovered_cursors: [
           %ProviderCursor{scope: "folder:gone", phase: "removed"}
         ],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)
    refute Repo.get_by(SyncCursor, external_account_id: account.id, scope: "folder:gone")
  end

  test "remote deletion records a tombstone without deleting accepted local history", %{
    account: account,
    cursor: cursor
  } do
    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [remote_message("message-delete")],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)
    mapping = Repo.get_by!(RemoteMessage, provider_message_id: "message-delete")
    delivery_id = mapping.inbound_delivery_id

    current = Repo.get!(SyncCursor, cursor.id)

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [%ProviderRemoteMessage{id: "message-delete", deleted?: true}],
         cursor: %{provider_cursor(current) | committed_cursor: "102"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)

    deleted = Repo.get!(RemoteMessage, mapping.id)
    assert deleted.remote_deleted
    assert deleted.state == "deleted"
    assert deleted.inbound_delivery_id == delivery_id
    assert Repo.get!(InboundDelivery, delivery_id)
  end

  test "folder move converges regardless of membership tombstone ordering", %{
    account: account,
    cursor: cursor,
    mailbox: mailbox
  } do
    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [remote_message("message-move")],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)
    mapping = Repo.get_by!(RemoteMessage, provider_message_id: "message-move")

    moved = %ProviderRemoteMessage{
      id: "message-move",
      folder_kind: "archive",
      folder_id: "archive-folder",
      read?: true,
      starred?: false
    }

    membership = %ProviderRemoteMessage{
      id: "message-move",
      folder_kind: "membership_tombstone",
      tombstone_kind: :membership
    }

    current = Repo.get!(SyncCursor, cursor.id)

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [membership, moved],
         cursor: %{provider_cursor(current) | committed_cursor: "102"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)
    assert Repo.get!(RemoteMessage, mapping.id).remote_folder_kind == "archive"

    current = Repo.get!(SyncCursor, cursor.id)

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [membership],
         cursor: %{provider_cursor(current) | committed_cursor: "103"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)
    assert Repo.get!(RemoteMessage, mapping.id).remote_folder_kind == "archive"

    assert :ok = Ingest.archive_delivery(mapping.inbound_delivery_id)
    assert :ok = Ingest.project_delivery(mapping.inbound_delivery_id)

    job = Repo.get_by!(Oban.Job, worker: inspect(ApplyRemoteState))
    assert :ok = ApplyRemoteState.perform(job)

    entry =
      Repo.get_by!(MailboxEntry,
        mailbox_id: mailbox.id,
        inbound_delivery_id: mapping.inbound_delivery_id
      )

    assert entry.folder_id == Manifold.Mail.Folders.get_system(mailbox.id, "archive").id
    assert %DateTime{} = entry.read_at
    assert is_nil(entry.starred_at)
  end

  test "Graph membership removal becomes deletion only after the message disappears", %{
    account: account,
    cursor: cursor
  } do
    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [remote_message("message-membership-delete")],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)
    mapping = Repo.get_by!(RemoteMessage, provider_message_id: "message-membership-delete")
    delivery_id = mapping.inbound_delivery_id

    Process.put(
      {:raw_result, "message-membership-delete"},
      {:error,
       %Error{
         class: :permanent,
         code: :not_found,
         message: "provider message no longer exists"
       }}
    )

    membership = %ProviderRemoteMessage{
      id: "message-membership-delete",
      folder_kind: "membership_tombstone",
      tombstone_kind: :membership
    }

    current = Repo.get!(SyncCursor, cursor.id)

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [membership],
         cursor: %{provider_cursor(current) | committed_cursor: "102"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)

    deleted = Repo.get!(RemoteMessage, mapping.id)
    assert deleted.remote_deleted
    assert deleted.inbound_delivery_id == delivery_id
  end

  test "missing Graph folder removes its stale cursor instead of failing the account", %{
    account: account,
    cursor: cursor
  } do
    cursor
    |> SyncCursor.changeset(%{
      scope: "folder:deleted-folder",
      phase: "steady",
      committed_cursor: "https://provider.test/deleted-folder"
    })
    |> Repo.update!()

    Process.put(
      :sync_page_result,
      {:error,
       %Error{
         class: :permanent,
         code: :not_found,
         message: "provider folder no longer exists"
       }}
    )

    assert :ok = Connectors.sync_account(account.id)
    refute Repo.get(SyncCursor, cursor.id)
    assert Repo.get!(ReceiveMethod, account.id).status == "connected"
  end

  test "message deleted between listing and raw fetch checkpoints a tombstone", %{
    account: account,
    cursor: cursor
  } do
    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [remote_message("message-gone")],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    Process.put(
      {:raw_result, "message-gone"},
      {:error,
       %Error{
         class: :permanent,
         code: :not_found,
         message: "provider message no longer exists"
       }}
    )

    assert :ok = Connectors.sync_account(account.id)

    tombstone =
      Repo.get_by!(RemoteMessage,
        external_account_id: account.id,
        provider_message_id: "message-gone"
      )

    assert tombstone.state == "deleted"
    assert tombstone.remote_deleted
    assert is_nil(tombstone.inbound_delivery_id)
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "101"
    assert Repo.aggregate(InboundDelivery, :count) == 0
  end

  test "queued synchronization cancels after disconnect without changing lifecycle state", %{
    account: account
  } do
    assert {:ok, disconnected} = Connectors.disconnect(account.id)
    assert disconnected.status == "disconnected"

    assert {:cancel, :account_disconnected} = Connectors.sync_account(account.id)

    persisted = Repo.get!(ReceiveMethod, account.id)
    assert persisted.status == "disconnected"
    refute persisted.sync_enabled
    assert is_nil(persisted.last_error_code)
  end

  test "remote state job waits for projection and then applies provider state", %{
    account: account,
    cursor: cursor,
    mailbox: mailbox
  } do
    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [remote_message("message-state")],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)
    mapping = Repo.get_by!(RemoteMessage, provider_message_id: "message-state")
    job = Repo.get_by!(Oban.Job, worker: inspect(ApplyRemoteState))

    assert {:snooze, 5} = ApplyRemoteState.perform(job)

    assert :ok = Ingest.archive_delivery(mapping.inbound_delivery_id)
    assert :ok = Ingest.project_delivery(mapping.inbound_delivery_id)
    assert :ok = ApplyRemoteState.perform(job)

    entry =
      Repo.get_by!(MailboxEntry,
        mailbox_id: mailbox.id,
        inbound_delivery_id: mapping.inbound_delivery_id
      )

    assert entry.read_at == nil
    assert %DateTime{} = entry.starred_at
    assert entry.folder_id == Manifold.Mail.Folders.get_system(mailbox.id, "inbox").id
  end

  defp remote_message(id) do
    %ProviderRemoteMessage{
      id: id,
      thread_id: "thread-" <> id,
      received_at: ~U[2026-07-29 01:00:00.000000Z],
      labels: ["INBOX", "STARRED", "UNREAD"],
      read?: false,
      starred?: true
    }
  end

  defp provider_cursor(cursor) do
    %ProviderCursor{
      scope: cursor.scope,
      phase: cursor.phase,
      bootstrap_cursor: cursor.bootstrap_cursor,
      page_cursor: cursor.page_cursor,
      committed_cursor: cursor.committed_cursor
    }
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end

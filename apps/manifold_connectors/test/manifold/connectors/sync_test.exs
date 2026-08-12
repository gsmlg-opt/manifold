defmodule Manifold.Connectors.SyncTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors

  alias Manifold.Connectors.{
    Crypto,
    MicrosoftFolderMapping,
    MicrosoftScopes,
    RemoteStateJobs
  }

  alias Manifold.Connectors.Jobs.{ApplyRemoteState, PollAccounts, SyncAccount}
  alias Manifold.Connectors.OAuth.Consumed

  alias Manifold.Connectors.Provider.{
    Error,
    FolderMapping,
    Identity,
    Page,
    RawMessage,
    Token
  }

  alias Manifold.Connectors.Provider.RemoteMessage, as: ProviderRemoteMessage
  alias Manifold.Connectors.Provider.SyncCursor, as: ProviderCursor

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    Credential,
    OAuthAuthorization,
    ReceiveMethod,
    RemoteMessage,
    SendMethod,
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

      Keyword.get(opts, :exchange_result) ||
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

      Process.get(:refresh_result) ||
        {:ok,
         %Token{
           access_token: "refreshed-access",
           refresh_token: "rotated-refresh",
           expires_at: DateTime.add(now, 3_600, :second),
           scopes: ["https://www.googleapis.com/auth/gmail.readonly"]
         }}
    end

    @impl true
    def identity("initial-access", _config, opts) do
      Keyword.get(opts, :identity_result) ||
        {:ok,
         %Identity{id: "sync-account", email_address: Keyword.fetch!(opts, :identity_address)}}
    end

    def identity(_access_token, _config, opts) do
      Keyword.fetch!(opts, :identity_result)
    end

    @impl true
    def initial_cursors("initial-access", _config, _opts) do
      {:ok, [%ProviderCursor{scope: "mailbox", phase: "initial", bootstrap_cursor: "100"}]}
    end

    @impl true
    def resolve_folder_mapping(access_token, _config, opts) do
      case Keyword.get(opts, :folder_mapping_gate) do
        nil ->
          Process.put(:folder_mapping_count, Process.get(:folder_mapping_count, 0) + 1)
          send(self(), {:folder_mapping_access_token, access_token})

          Process.get(:folder_mapping_result) ||
            {:ok,
             %FolderMapping{
               version: 1,
               kinds_by_id: %{
                 "folder-inbox" => "inbox",
                 "folder-deleted" => "trash",
                 "folder-sent" => "sent"
               }
             }}

        gate ->
          test_pid = Keyword.fetch!(opts, :test_pid)
          send(test_pid, {:folder_mapping_started, self(), gate, access_token})

          receive do
            {:release_folder_mapping, ^gate, %FolderMapping{} = mapping} -> {:ok, mapping}
          end
      end
    end

    @impl true
    def sync_page(access_token, cursor, _config, opts) do
      send(self(), {:sync_access_token, access_token})

      if test_pid = Keyword.get(opts, :test_pid) do
        send(
          test_pid,
          {:sync_page_called, Keyword.get(opts, :folder_mapping_gate), access_token, cursor}
        )
      end

      case Process.get(:sync_page_result) do
        nil ->
          {:ok,
           %Page{
             cursor: %{cursor | phase: "incremental", committed_cursor: "101"}
           }}

        fun when is_function(fun, 1) ->
          fun.(cursor)

        result ->
          result
      end
    end

    @impl true
    def fetch_raw(access_token, message_id, _config, _opts) do
      Process.put(:raw_fetch_count, Process.get(:raw_fetch_count, 0) + 1)
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
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})

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

    Application.put_env(:manifold_connectors, :adapters,
      gmail: FakeProvider,
      microsoft: FakeProvider
    )

    Application.put_env(:manifold_connectors, :providers,
      gmail: [client_id: "client"],
      microsoft: [client_id: "client"]
    )

    Application.put_env(:manifold_storage, :spool_dir, Path.join(tmp_dir, "spool"))
    Application.put_env(:manifold_storage, :raw_store_dir, Path.join(tmp_dir, "raw"))

    on_exit(fn ->
      restore_env(:manifold_connectors, :encryption_key, old_key)
      restore_env(:manifold_connectors, :adapters, old_adapters)
      restore_env(:manifold_connectors, :providers, old_providers)
      Application.put_env(:manifold_storage, :spool_dir, old_spool)
      Application.put_env(:manifold_storage, :raw_store_dir, old_raw)
      Process.delete(:sync_page_result)
      Process.delete(:refresh_result)
      Process.delete(:folder_mapping_count)
      Process.delete(:folder_mapping_result)
      Process.delete(:raw_fetch_count)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "sync#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "person"})
    mailbox = Repo.preload(mailbox, :domain)
    address = Accounts.account_address(mailbox)

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
               provider_opts: [now: DateTime.utc_now(), identity_address: address]
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
    authorization = Repo.get!(OAuthAuthorization, account.oauth_authorization_id)

    authorization
    |> OAuthAuthorization.changeset(%{
      token_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })
    |> Repo.update!()

    assert :ok = Connectors.sync_account(account.id)
    assert_receive {:sync_access_token, "refreshed-access"}

    updated = Repo.get!(OAuthAuthorization, authorization.id)

    assert {:ok, "rotated-refresh"} =
             Crypto.decrypt(
               updated.refresh_token_ciphertext,
               "credential:#{authorization.id}:refresh"
             )

    refute Repo.get_by(Credential, external_account_id: account.id)
  end

  test "Microsoft sync checks out Mail.Read from shared authorization without a Credential row",
       %{
         account: account
       } do
    microsoft = account.id |> then(&Repo.get!(ReceiveMethod, &1)) |> convert_to_microsoft!()

    refute Repo.get_by(Credential, external_account_id: microsoft.id)

    assert :ok = Connectors.sync_account(microsoft.id)
    assert_receive {:sync_access_token, "initial-access"}
    refute Repo.get_by(Credential, external_account_id: microsoft.id)
  end

  test "Microsoft selected-lane sync repairs upgraded folder mappings without raw fetches", %{
    account: account,
    cursor: cursor,
    mailbox: mailbox
  } do
    fixture = upgraded_microsoft_fixture!(account, cursor, mailbox)
    attach_folder_mapping_stop()

    Process.put(:folder_mapping_count, 0)
    Process.put(:raw_fetch_count, 0)

    Process.put(:sync_page_result, fn provider_cursor ->
      assert provider_cursor.scope == fixture.selected.scope
      assert provider_cursor.committed_cursor == fixture.selected.committed_cursor
      assert provider_cursor.metadata["folder_mapping_version"] == 1
      assert provider_cursor.metadata["folder_kind"] == "inbox"
      send(self(), {:selected_lane_synced, provider_cursor.scope})
      {:ok, %Page{cursor: provider_cursor}}
    end)

    assert :ok = Connectors.sync_account(fixture.account.id)
    assert_receive {:selected_lane_synced, "folder:folder-inbox"}
    assert_receive {:folder_mapping_access_token, "initial-access"}

    assert_receive {:folder_mapping_stop, measurements, metadata}
    assert measurements.cursor_count == 2
    assert measurements.changed_message_count == 3

    assert metadata == %{
             account_id: fixture.account.account_id,
             error_code: nil,
             method_id: fixture.account.id,
             outcome: :repaired,
             provider: "microsoft"
           }

    refreshed_folders = Repo.get!(SyncCursor, fixture.folders.id)
    refreshed_selected = Repo.get!(SyncCursor, fixture.selected.id)

    assert refreshed_folders.committed_cursor == fixture.folders.committed_cursor
    assert refreshed_selected.committed_cursor == fixture.selected.committed_cursor
    assert refreshed_folders.metadata["folder_mapping_version"] == 1

    assert refreshed_folders.metadata["folder_kinds_by_id"] == %{
             "folder-inbox" => "inbox",
             "folder-deleted" => "trash",
             "folder-sent" => "sent"
           }

    assert Repo.get!(RemoteMessage, fixture.remotes.inbox.id).remote_folder_kind == "inbox"
    assert Repo.get!(RemoteMessage, fixture.remotes.deleted.id).remote_folder_kind == "trash"
    assert Repo.get!(RemoteMessage, fixture.remotes.sent.id).remote_folder_kind == "sent"
    assert Repo.get!(RemoteMessage, fixture.remotes.custom.id).remote_folder_kind == "archive"

    assert Enum.all?(
             [fixture.remotes.inbox, fixture.remotes.deleted, fixture.remotes.sent],
             fn remote ->
               apply_remote_state_job_count(remote.id) == 1
             end
           )

    assert apply_remote_state_job_count(fixture.remotes.custom.id) == 0

    assert Process.get(:folder_mapping_count) == 1
    assert Process.get(:raw_fetch_count) == 0

    cursor_positions = cursor_position_snapshots(fixture.account.id)
    remote_snapshots = remote_state_snapshots(fixture.account.id)
    job_ids = apply_remote_state_job_ids(fixture.account.id)

    assert {:ok, %SyncCursor{id: selected_id}} =
             MicrosoftFolderMapping.ensure_current(
               Repo.get!(ReceiveMethod, fixture.account.id),
               refreshed_selected,
               "initial-access",
               FakeProvider,
               [],
               []
             )

    assert selected_id == refreshed_selected.id
    assert cursor_position_snapshots(fixture.account.id) == cursor_positions
    assert remote_state_snapshots(fixture.account.id) == remote_snapshots
    assert apply_remote_state_job_ids(fixture.account.id) == job_ids
    assert Process.get(:folder_mapping_count) == 1
    assert Process.get(:raw_fetch_count) == 0
  end

  test "Microsoft repair queues one successor behind an executing remote-state job", %{
    account: account,
    cursor: cursor,
    mailbox: mailbox
  } do
    fixture = upgraded_microsoft_fixture!(account, cursor, mailbox)
    remote = fixture.remotes.inbox

    executing =
      remote.id
      |> then(&ApplyRemoteState.new(%{"remote_message_id" => &1}))
      |> Repo.insert!()

    {1, nil} =
      Oban.Job
      |> where([job], job.id == ^executing.id)
      |> Repo.update_all(set: [state: "executing"])

    assert {:ok, %SyncCursor{}} =
             MicrosoftFolderMapping.ensure_current(
               Repo.get!(ReceiveMethod, fixture.account.id),
               fixture.selected,
               "initial-access",
               FakeProvider,
               [],
               []
             )

    assert Repo.get!(Oban.Job, executing.id).state == "executing"

    assert [%Oban.Job{} = successor] = queued_remote_state_jobs(remote.id)
    assert successor.id != executing.id

    assert %Oban.Job{id: successor_id} = RemoteStateJobs.ensure(remote.id)
    assert successor_id == successor.id
    assert [^successor] = queued_remote_state_jobs(remote.id)

    archive = Manifold.Mail.Folders.get_system(mailbox.id, "archive")
    inbox = Manifold.Mail.Folders.get_system(mailbox.id, "inbox")

    assert Repo.get_by!(MailboxEntry, inbound_delivery_id: remote.inbound_delivery_id).folder_id ==
             archive.id

    assert :ok = ApplyRemoteState.perform(successor)

    assert Repo.get_by!(MailboxEntry, inbound_delivery_id: remote.inbound_delivery_id).folder_id ==
             inbox.id
  end

  test "Microsoft reset metadata forces mapping resolution before the selected page", %{
    account: account,
    cursor: cursor
  } do
    microsoft = convert_to_microsoft!(account)

    cursor
    |> Repo.reload!()
    |> SyncCursor.changeset(%{last_completed_at: ~U[2026-08-12 02:00:00.000000Z]})
    |> Repo.update!()

    selected =
      insert_sync_cursor!(microsoft.id, %{
        scope: "folder:folder-sent",
        phase: "incremental",
        committed_cursor: "https://graph.microsoft.test/messages/sent-delta",
        metadata: %{
          "folder_kind" => "archive",
          "folder_mapping_version" => 1,
          "folder_mapping_refresh_required" => true
        }
      })

    Process.put(:folder_mapping_count, 0)
    Process.put(:raw_fetch_count, 0)

    Process.put(:sync_page_result, fn provider_cursor ->
      assert provider_cursor.scope == selected.scope
      assert provider_cursor.metadata["folder_kind"] == "sent"
      refute Map.has_key?(provider_cursor.metadata, "folder_mapping_refresh_required")
      {:ok, %Page{cursor: provider_cursor}}
    end)

    assert :ok = Connectors.sync_account(microsoft.id)
    assert Process.get(:folder_mapping_count) == 1
    assert Process.get(:raw_fetch_count) == 0

    refreshed_folders = Repo.get!(SyncCursor, cursor.id)
    refreshed_selected = Repo.get!(SyncCursor, selected.id)

    assert refreshed_folders.committed_cursor == cursor.committed_cursor
    assert refreshed_selected.committed_cursor == selected.committed_cursor
    assert refreshed_selected.metadata["folder_mapping_version"] == 1
    refute Map.has_key?(refreshed_selected.metadata, "folder_mapping_refresh_required")
  end

  test "Microsoft mapping failures use provider throttling before cursor advancement", %{
    account: account,
    cursor: cursor
  } do
    microsoft = convert_to_microsoft!(account)

    cursor
    |> Repo.reload!()
    |> SyncCursor.changeset(%{metadata: %{"folder_mapping_refresh_required" => true}})
    |> Repo.update!()

    Process.put(:folder_mapping_count, 0)

    Process.put(
      :folder_mapping_result,
      {:error,
       %Error{
         class: :temporary,
         code: :rate_limited,
         message: "Microsoft Graph rate limited folder discovery",
         retry_after_seconds: 47
       }}
    )

    assert {:snooze, 47} = Connectors.sync_account(microsoft.id)
    assert Process.get(:folder_mapping_count) == 1
    refute_receive {:sync_access_token, "initial-access"}
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == cursor.committed_cursor
    assert Repo.get!(ReceiveMethod, microsoft.id).last_error_code == "rate_limited"
  end

  test "Microsoft reconnect fences an in-flight mapping result before the provider page", %{
    account: account,
    cursor: cursor,
    mailbox: mailbox
  } do
    microsoft = convert_to_microsoft!(account)
    authorization = Repo.get!(OAuthAuthorization, microsoft.oauth_authorization_id)

    stale_cursor =
      cursor
      |> Repo.reload!()
      |> SyncCursor.changeset(%{
        metadata: %{
          "folder_kinds_by_id" => %{"folder-inbox" => "archive"},
          "folder_mapping_refresh_required" => true
        }
      })
      |> Repo.update!()

    stale_gate = make_ref()
    test_pid = self()

    stale_sync =
      Task.async(fn ->
        Connectors.sync_account(microsoft.id,
          provider_opts: [test_pid: test_pid, folder_mapping_gate: stale_gate]
        )
      end)

    assert_receive {:folder_mapping_started, resolver_pid, ^stale_gate, "initial-access"}, 5_000

    assert {:ok, _authorization} =
             Connectors.mark_oauth_reconnect_required(
               authorization.id,
               %Error{
                 class: :reconnect,
                 code: :invalid_grant,
                 message: "provider reconnect required"
               }
             )

    required_scopes = Enum.sort([MicrosoftScopes.read(), MicrosoftScopes.offline()])

    consumed = %Consumed{
      provider: "microsoft",
      mailbox_id: mailbox.id,
      purpose: :receive,
      required_scopes: required_scopes,
      redirect_uri: "https://mail.example.test/connectors/microsoft/callback",
      pkce_verifier: "verifier"
    }

    reconnect_token = %Token{
      access_token: "reconnected-access",
      refresh_token: "reconnected-refresh",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
      scopes: [MicrosoftScopes.read()]
    }

    reconnect_identity = %Identity{
      id: "sync-account",
      email_address: Accounts.account_address(mailbox)
    }

    assert {:ok, %ReceiveMethod{id: method_id, status: "connected"}} =
             Connectors.complete_authorization(
               "microsoft",
               "valid-code",
               consumed,
               provider_opts: [
                 exchange_result: {:ok, reconnect_token},
                 identity_result: {:ok, reconnect_identity}
               ]
             )

    assert method_id == microsoft.id

    invalidated = Repo.get!(SyncCursor, stale_cursor.id)
    assert invalidated.metadata["folder_mapping_refresh_required"]
    refute Map.has_key?(invalidated.metadata, "folder_mapping_version")

    stale_mapping = %FolderMapping{
      version: 1,
      kinds_by_id: %{"folder-inbox" => "archive"}
    }

    send(resolver_pid, {:release_folder_mapping, stale_gate, stale_mapping})

    assert {:snooze, 1} = Task.await(stale_sync, 5_000)
    refute_receive {:sync_page_called, ^stale_gate, _access_token, _cursor}, 100

    after_stale = Repo.get!(SyncCursor, stale_cursor.id)
    assert after_stale.metadata["folder_mapping_refresh_required"]
    refute Map.has_key?(after_stale.metadata, "folder_mapping_version")

    fresh_gate = make_ref()

    fresh_sync =
      Task.async(fn ->
        Connectors.sync_account(microsoft.id,
          provider_opts: [test_pid: test_pid, folder_mapping_gate: fresh_gate]
        )
      end)

    assert_receive {:folder_mapping_started, fresh_resolver_pid, ^fresh_gate,
                    "reconnected-access"},
                   5_000

    fresh_mapping = %FolderMapping{
      version: 1,
      kinds_by_id: %{"folder-inbox" => "inbox"}
    }

    send(fresh_resolver_pid, {:release_folder_mapping, fresh_gate, fresh_mapping})

    assert_receive {:sync_page_called, ^fresh_gate, "reconnected-access", page_cursor}, 5_000
    assert page_cursor.metadata["folder_mapping_version"] == 1
    assert page_cursor.metadata["folder_kinds_by_id"] == %{"folder-inbox" => "inbox"}
    refute Map.has_key?(page_cursor.metadata, "folder_mapping_refresh_required")
    assert :ok = Task.await(fresh_sync, 5_000)
  end

  test "Microsoft reconnect errors pause the shared authorization and both methods", %{
    account: account,
    cursor: cursor
  } do
    microsoft = convert_to_microsoft!(account)
    send_method = insert_oauth_send_method!(microsoft, "microsoft")
    authorization = Repo.get!(OAuthAuthorization, microsoft.oauth_authorization_id)
    attach_sync_stop()

    Process.put(
      :sync_page_result,
      {:error,
       %Error{
         class: :reconnect,
         code: :invalid_grant,
         message: "microsoft-provider-secret-must-not-escape"
       }}
    )

    assert {:cancel, :reconnect_required} = Connectors.sync_account(microsoft.id)
    assert_receive {:sync_stop, %{provider: "microsoft", error_message: sanitized}}
    assert sanitized == "Microsoft authorization must be reconnected"
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "100"

    assert_oauth_reconnect_required(
      "Microsoft",
      authorization.id,
      microsoft.id,
      send_method.id
    )

    refute_reconnect_secret("microsoft-provider-secret-must-not-escape")
  end

  test "polling remains unique for 300 seconds and creates no webhook job", %{account: account} do
    _microsoft = convert_to_microsoft!(account)
    Repo.delete_all(Oban.Job)

    unique = SyncAccount.__opts__()[:unique]
    assert unique[:period] == 300
    assert unique[:keys] == [:external_account_id]
    assert unique[:states] == :incomplete

    assert :ok = PollAccounts.perform(%Oban.Job{args: %{}})
    assert :ok = PollAccounts.perform(%Oban.Job{args: %{}})

    assert [%Oban.Job{worker: worker, args: %{"external_account_id" => method_id}}] =
             Repo.all(Oban.Job)

    assert worker == inspect(SyncAccount)
    assert method_id == account.id
    refute String.contains?(worker, "Webhook")
  end

  test "Gmail sync-page reconnect pauses the shared authorization and both methods", %{
    account: account,
    cursor: cursor
  } do
    send_method = insert_gmail_send_method!(account)
    authorization = Repo.get!(OAuthAuthorization, account.oauth_authorization_id)
    attach_sync_stop()

    Process.put(
      :sync_page_result,
      {:error,
       %Error{
         class: :reconnect,
         code: :invalid_grant,
         message: "raw-sync-page-secret must never escape"
       }}
    )

    assert {:cancel, :reconnect_required} = Connectors.sync_account(account.id)
    assert_receive {:sync_stop, %{provider: "gmail", error_message: sanitized}}
    assert sanitized == "Gmail authorization must be reconnected"
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "100"
    assert_gmail_reconnect_required(authorization.id, account.id, send_method.id)
    refute_reconnect_secret("raw-sync-page-secret")
  end

  test "Gmail checkout reconnect reports Gmail telemetry and pauses both methods", %{
    account: account,
    cursor: cursor
  } do
    send_method = insert_gmail_send_method!(account)
    authorization = Repo.get!(OAuthAuthorization, account.oauth_authorization_id)
    attach_sync_stop()

    authorization
    |> OAuthAuthorization.changeset(%{token_expires_at: DateTime.add(DateTime.utc_now(), -60)})
    |> Repo.update!()

    Process.put(
      :refresh_result,
      {:error,
       %Error{
         class: :reconnect,
         code: :invalid_grant,
         message: "raw-checkout-secret must never escape"
       }}
    )

    assert {:cancel, :reconnect_required} = Connectors.sync_account(account.id)
    assert_receive {:sync_stop, %{provider: "gmail", error_message: sanitized}}
    assert sanitized == "Gmail authorization must be reconnected"
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "100"
    assert_gmail_reconnect_required(authorization.id, account.id, send_method.id)
    refute_reconnect_secret("raw-checkout-secret")
  end

  test "Gmail raw-fetch reconnect pauses the shared authorization and both methods", %{
    account: account,
    cursor: cursor
  } do
    send_method = insert_gmail_send_method!(account)
    authorization = Repo.get!(OAuthAuthorization, account.oauth_authorization_id)
    attach_sync_stop()

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: [remote_message("message-reconnect")],
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    Process.put(
      {:raw_result, "message-reconnect"},
      {:error,
       %Error{
         class: :reconnect,
         code: :authentication_expired,
         message: "raw-fetch-secret must never escape"
       }}
    )

    assert {:cancel, :reconnect_required} = Connectors.sync_account(account.id)
    assert_receive {:sync_stop, %{provider: "gmail", error_message: sanitized}}
    assert sanitized == "Gmail authorization must be reconnected"
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "100"
    assert_gmail_reconnect_required(authorization.id, account.id, send_method.id)
    refute_reconnect_secret("raw-fetch-secret")
  end

  test "a reconnect race makes the stale checkpoint cancel without restoring connected", %{
    account: account,
    cursor: cursor
  } do
    send_method = insert_gmail_send_method!(account)
    authorization = Repo.get!(OAuthAuthorization, account.oauth_authorization_id)

    Process.put(:sync_page_result, fn provider_cursor ->
      assert {:ok, _authorization} =
               Connectors.mark_oauth_reconnect_required(
                 authorization.id,
                 %Error{
                   class: :reconnect,
                   code: :invalid_grant,
                   message: "raw-checkpoint-race-secret must never escape"
                 },
                 expected_access_token: "initial-access"
               )

      {:ok,
       %Page{
         cursor: %{provider_cursor | committed_cursor: "101"}
       }}
    end)

    assert {:cancel, :reconnect_required} = Connectors.sync_account(account.id)
    assert Repo.get!(SyncCursor, cursor.id).committed_cursor == "100"
    assert_gmail_reconnect_required(authorization.id, account.id, send_method.id)
    refute_reconnect_secret("raw-checkpoint-race-secret")
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

  defp upgraded_microsoft_fixture!(account, cursor, mailbox) do
    folder_ids = %{
      inbox: "folder-inbox",
      deleted: "folder-deleted",
      sent: "folder-sent",
      custom: "folder-custom"
    }

    messages =
      Enum.map(folder_ids, fn {kind, _folder_id} ->
        %{remote_message("upgraded-#{kind}") | folder_kind: "archive", labels: []}
      end)

    Process.put(
      :sync_page_result,
      {:ok,
       %Page{
         messages: messages,
         cursor: %{provider_cursor(cursor) | committed_cursor: "101"}
       }}
    )

    assert :ok = Connectors.sync_account(account.id)

    remotes =
      Map.new(folder_ids, fn {kind, folder_id} ->
        remote =
          Repo.get_by!(RemoteMessage,
            external_account_id: account.id,
            provider_message_id: "upgraded-#{kind}"
          )

        assert :ok = Ingest.archive_delivery(remote.inbound_delivery_id)
        assert :ok = Ingest.project_delivery(remote.inbound_delivery_id)

        repaired_fixture =
          remote
          |> RemoteMessage.changeset(%{
            remote_folder_id: folder_id,
            remote_folder_kind: "archive"
          })
          |> Repo.update!()

        assert :ok = Connectors.apply_remote_state(repaired_fixture.id)

        {kind, repaired_fixture}
      end)

    archive = Manifold.Mail.Folders.get_system(mailbox.id, "archive")

    assert Enum.all?(Map.values(remotes), fn remote ->
             Repo.get_by!(MailboxEntry, inbound_delivery_id: remote.inbound_delivery_id).folder_id ==
               archive.id
           end)

    microsoft =
      account.id
      |> then(&Repo.get!(ReceiveMethod, &1))
      |> convert_to_microsoft!()

    Repo.delete_all(from(job in Oban.Job, where: job.worker == ^inspect(ApplyRemoteState)))

    Repo.delete_all(
      from(stored in SyncCursor, where: stored.external_account_id == ^microsoft.id)
    )

    folders =
      insert_sync_cursor!(microsoft.id, %{
        scope: "folders",
        phase: "incremental",
        committed_cursor: "https://graph.microsoft.test/folders/committed-delta",
        metadata: %{},
        last_completed_at: ~U[2026-08-12 02:00:00.000000Z]
      })

    selected =
      insert_sync_cursor!(microsoft.id, %{
        scope: "folder:folder-inbox",
        phase: "incremental",
        committed_cursor: "https://graph.microsoft.test/messages/inbox-committed-delta",
        metadata: %{"folder_kind" => "archive"}
      })

    %{account: microsoft, folders: folders, selected: selected, remotes: remotes}
  end

  defp insert_sync_cursor!(receive_method_id, attrs) do
    defaults = %{
      external_account_id: receive_method_id,
      phase: "incremental",
      metadata: %{},
      generation: 1
    }

    %SyncCursor{}
    |> SyncCursor.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp cursor_position_snapshots(receive_method_id) do
    SyncCursor
    |> where([cursor], cursor.external_account_id == ^receive_method_id)
    |> order_by([cursor], asc: cursor.id)
    |> Repo.all()
    |> Enum.map(
      &Map.take(&1, [
        :id,
        :scope,
        :phase,
        :bootstrap_cursor,
        :page_cursor,
        :committed_cursor,
        :generation,
        :last_completed_at
      ])
    )
  end

  defp remote_state_snapshots(receive_method_id) do
    RemoteMessage
    |> where([remote], remote.external_account_id == ^receive_method_id)
    |> order_by([remote], asc: remote.id)
    |> Repo.all()
    |> Enum.map(&Map.take(&1, [:id, :remote_folder_kind, :lock_version, :updated_at]))
  end

  defp apply_remote_state_job_ids(receive_method_id) do
    remote_ids =
      RemoteMessage
      |> where([remote], remote.external_account_id == ^receive_method_id)
      |> select([remote], remote.id)
      |> Repo.all()
      |> MapSet.new()

    Oban.Job
    |> where([job], job.worker == ^inspect(ApplyRemoteState))
    |> order_by([job], asc: job.id)
    |> Repo.all()
    |> Enum.filter(&MapSet.member?(remote_ids, &1.args["remote_message_id"]))
    |> Enum.map(& &1.id)
  end

  defp apply_remote_state_job_count(remote_message_id) do
    Oban.Job
    |> where([job], job.worker == ^inspect(ApplyRemoteState))
    |> where(
      [job],
      fragment("?->>'remote_message_id' = ?", job.args, ^remote_message_id)
    )
    |> Repo.aggregate(:count)
  end

  defp queued_remote_state_jobs(remote_message_id) do
    Oban.Job
    |> where([job], job.worker == ^inspect(ApplyRemoteState))
    |> where([job], job.state in ~w(available scheduled retryable suspended))
    |> where(
      [job],
      fragment("?->>'remote_message_id' = ?", job.args, ^remote_message_id)
    )
    |> order_by([job], asc: job.id)
    |> Repo.all()
  end

  defp attach_folder_mapping_stop do
    handler_id = "microsoft-folder-mapping-stop-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :connectors, :microsoft, :folder_mapping, :stop],
        fn _event, measurements, metadata, pid ->
          send(pid, {:folder_mapping_stop, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
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
      committed_cursor: cursor.committed_cursor,
      metadata: cursor.metadata
    }
  end

  defp insert_gmail_send_method!(receive_method) do
    insert_oauth_send_method!(receive_method, "gmail")
  end

  defp insert_oauth_send_method!(receive_method, provider) do
    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: receive_method.account_id,
      oauth_authorization_id: receive_method.oauth_authorization_id,
      kind: provider,
      email_address: receive_method.email_address,
      status: "connected",
      enabled: true
    })
    |> Repo.insert!()
  end

  defp convert_to_microsoft!(receive_method) do
    receive_method.oauth_authorization_id
    |> then(&Repo.get!(OAuthAuthorization, &1))
    |> OAuthAuthorization.changeset(%{
      provider: "microsoft",
      granted_scopes: [MicrosoftScopes.read(), MicrosoftScopes.offline()]
    })
    |> Repo.update!()

    microsoft =
      receive_method
      |> ReceiveMethod.changeset(%{
        kind: "microsoft",
        granted_scopes: [MicrosoftScopes.read()]
      })
      |> Repo.update!()

    microsoft.id
    |> then(&Repo.get_by!(SyncCursor, external_account_id: &1))
    |> SyncCursor.changeset(%{
      scope: "folders",
      metadata: %{
        "folder_mapping_version" => 1,
        "folder_kinds_by_id" => %{
          "folder-inbox" => "inbox",
          "folder-deleted" => "trash",
          "folder-sent" => "sent"
        }
      }
    })
    |> Repo.update!()

    microsoft
  end

  defp attach_sync_stop do
    handler_id = "gmail-sync-stop-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :connectors, :sync, :stop],
        fn _event, _measurements, metadata, pid -> send(pid, {:sync_stop, metadata}) end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp assert_gmail_reconnect_required(authorization_id, receive_method_id, send_method_id) do
    assert_oauth_reconnect_required(
      "Gmail",
      authorization_id,
      receive_method_id,
      send_method_id
    )
  end

  defp assert_oauth_reconnect_required(
         provider_name,
         authorization_id,
         receive_method_id,
         send_method_id
       ) do
    expected_message = "#{provider_name} authorization must be reconnected"
    authorization = Repo.get!(OAuthAuthorization, authorization_id)
    assert authorization.status == "reconnect_required"
    assert authorization.last_error_class == "reconnect"
    assert authorization.last_error_message == expected_message

    receive_method = Repo.get!(ReceiveMethod, receive_method_id)
    assert receive_method.status == "reconnect_required"
    refute receive_method.enabled
    refute receive_method.sync_enabled
    assert receive_method.last_error_message == expected_message

    send_method = Repo.get!(SendMethod, send_method_id)
    assert send_method.status == "reconnect_required"
    refute send_method.enabled
    assert send_method.last_error_message == expected_message

    assert Repo.get_by!(ConnectorEvent,
             oauth_authorization_id: authorization_id,
             event_type: "reconnect_required"
           )
  end

  defp refute_reconnect_secret(secret) do
    refute Enum.any?(Repo.all(ConnectorEvent), &(inspect(&1) =~ secret))
    refute Enum.any?(Repo.all(ReceiveMethod), &(inspect(&1) =~ secret))
    refute Enum.any?(Repo.all(SendMethod), &(inspect(&1) =~ secret))
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end

defmodule Manifold.Connectors.RemoteStateJobsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Manifold.Connectors.Jobs.ApplyRemoteState
  alias Manifold.Connectors.RemoteStateJobs
  alias Manifold.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    oban_opts =
      :manifold_data
      |> Application.fetch_env!(Oban)
      |> Keyword.put(:testing, :disabled)
      |> Keyword.put(:queues, [])
      |> Keyword.put(:plugins, [])
      |> Keyword.put(:peer, {Oban.Peers.Isolated, leader?: false})
      |> Keyword.put(:stage_interval, :infinity)

    start_supervised!({Oban, oban_opts})

    remote_message_id = Ecto.UUID.generate()

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        delete_remote_state_jobs(remote_message_id)
      after
        Sandbox.checkin(Repo)
      end
    end)

    {:ok, remote_message_id: remote_message_id}
  end

  test "concurrent ensures persist one queued job", %{remote_message_id: remote_message_id} do
    test_pid = self()
    gate = make_ref()

    tasks =
      for _index <- 1..20 do
        Task.async(fn ->
          send(test_pid, {:remote_state_ensure_ready, self(), gate})

          receive do
            {:ensure_remote_state, ^gate} -> :ok
          end

          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            RemoteStateJobs.ensure(remote_message_id)
          after
            Sandbox.checkin(Repo)
          end
        end)
      end

    caller_pids =
      for _index <- 1..20 do
        assert_receive {:remote_state_ensure_ready, caller_pid, ^gate}, 5_000
        caller_pid
      end

    Enum.each(caller_pids, &send(&1, {:ensure_remote_state, gate}))

    assert Enum.all?(Task.await_many(tasks, 10_000), &match?(%Oban.Job{}, &1))
    assert [_job] = queued_remote_state_jobs(remote_message_id)
  end

  test "job insertion rolls back with the surrounding transaction", %{
    remote_message_id: remote_message_id
  } do
    assert {:error, :forced_rollback} =
             Repo.transaction(fn ->
               assert %Oban.Job{} = RemoteStateJobs.ensure(remote_message_id)
               assert [_job] = queued_remote_state_jobs(remote_message_id)
               Repo.rollback(:forced_rollback)
             end)

    assert [] = queued_remote_state_jobs(remote_message_id)
  end

  defp queued_remote_state_jobs(remote_message_id) do
    Oban.Job
    |> where([job], job.worker == ^inspect(ApplyRemoteState))
    |> where([job], job.state in ~w(available scheduled retryable suspended))
    |> where(
      [job],
      fragment("?->>'remote_message_id' = ?", job.args, ^remote_message_id)
    )
    |> order_by([job], asc: job.id)
    |> Repo.all()
  end

  defp delete_remote_state_jobs(remote_message_id) do
    Oban.Job
    |> where([job], job.worker == ^inspect(ApplyRemoteState))
    |> where(
      [job],
      fragment("?->>'remote_message_id' = ?", job.args, ^remote_message_id)
    )
    |> Repo.delete_all()
  end
end

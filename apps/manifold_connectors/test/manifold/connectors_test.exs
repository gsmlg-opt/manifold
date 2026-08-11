defmodule Manifold.ConnectorsTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Accounts.Schema.Account
  alias Manifold.Connectors
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.EAS.Fake, as: EasFake
  alias Manifold.Connectors.Jobs.{ApplyRemoteState, PollAccounts, PushRemoteRead, SyncAccount}
  alias Manifold.Connectors.OAuth.Consumed
  alias Manifold.Connectors.Provider.{Identity, Page, RawMessage, Token}
  alias Manifold.Connectors.Provider.SyncCursor, as: ProviderCursor
  alias Manifold.Ingest.Schema.InboundDelivery
  alias Manifold.Mail
  alias Manifold.Mail.Schema.{MailboxEntry, Message, Thread}

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    Credential,
    OAuthAuthorization,
    OAuthTransaction,
    ReceiveMethod,
    RemoteMessage,
    SendCredential,
    SendMethod,
    SmtpSettings,
    SyncCursor
  }

  alias Manifold.Repo

  defmodule FakeMicrosoft do
    @behaviour Manifold.Connectors.Provider

    @impl true
    def exchange_code("valid-code", "verifier", _redirect_uri, _config, _opts) do
      {:ok,
       %Token{
         access_token: "access-secret",
         refresh_token: "refresh-secret",
         expires_at: ~U[2026-07-29 02:00:00.000000Z],
         scopes: ["Mail.Read", "offline_access"]
       }}
    end

    def exchange_code(_code, _verifier, _redirect_uri, _config, _opts) do
      {:error,
       %Manifold.Connectors.Provider.Error{
         class: :permanent,
         code: :invalid_code,
         message: "authorization code is invalid"
       }}
    end

    @impl true
    def refresh_token(_refresh_token, _config, _opts), do: raise("not used")

    @impl true
    def identity("access-secret", _config, _opts) do
      {:ok, %Identity{id: "microsoft-subject-1", email_address: "person@microsoft.example"}}
    end

    @impl true
    def initial_cursors("access-secret", _config, _opts) do
      {:ok, [%ProviderCursor{scope: "mailbox", phase: "bootstrap"}]}
    end

    @impl true
    def sync_page(_access_token, cursor, _config, _opts),
      do: {:ok, %Page{cursor: cursor}}

    @impl true
    def fetch_raw(_access_token, _message_id, _config, _opts),
      do: {:ok, %RawMessage{bytes: "Subject: test\r\n\r\nBody\r\n"}}
  end

  setup do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_adapters = Application.get_env(:manifold_connectors, :adapters)
    old_providers = Application.get_env(:manifold_connectors, :providers)
    old_eas_transport = Application.get_env(:manifold_connectors, :eas_transport)
    old_eas_fake = Application.get_env(:manifold_connectors, :eas_fake)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :adapters, microsoft: FakeMicrosoft)
    Application.put_env(:manifold_connectors, :eas_transport, EasFake)

    Application.put_env(:manifold_connectors, :eas_fake, %{
      password_expected: "secret",
      messages: []
    })

    Application.put_env(:manifold_connectors, :providers,
      microsoft: [
        client_id: "client",
        client_secret: "secret",
        authorization_url: "https://accounts.google.test/authorize"
      ]
    )

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:adapters, old_adapters)
      restore_env(:providers, old_providers)
      restore_env(:eas_transport, old_eas_transport)
      restore_env(:eas_fake, old_eas_fake)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "connector#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "person"})
    {:ok, domain: domain, mailbox: mailbox}
  end

  test "OAuth completion stores encrypted credentials, cursors, event, and job atomically", %{
    mailbox: mailbox
  } do
    consumed = consumed(mailbox.id)

    assert {:ok, account} =
             Connectors.complete_authorization("microsoft", "valid-code", consumed,
               now: ~U[2026-07-29 01:00:00.000000Z]
             )

    assert account.kind == "microsoft"
    assert account.provider_account_id == "microsoft-subject-1"
    assert account.email_address == "person@microsoft.example"
    assert account.account_id == mailbox.id
    assert account.status == "connected"

    credential = Repo.get_by!(Credential, external_account_id: account.id)
    refute credential.access_token_ciphertext =~ "access-secret"
    refute credential.refresh_token_ciphertext =~ "refresh-secret"

    assert {:ok, "access-secret"} =
             Crypto.decrypt(
               credential.access_token_ciphertext,
               "credential:#{account.id}:access"
             )

    assert {:ok, "refresh-secret"} =
             Crypto.decrypt(
               credential.refresh_token_ciphertext,
               "credential:#{account.id}:refresh"
             )

    assert %SyncCursor{scope: "mailbox", phase: "bootstrap"} =
             Repo.get_by!(SyncCursor, external_account_id: account.id)

    legacy_event =
      Repo.get_by!(ConnectorEvent,
        external_account_id: account.id,
        event_type: "connected"
      )

    assert is_nil(legacy_event.oauth_authorization_id)

    assert Repo.get_by!(Oban.Job,
             worker: inspect(SyncAccount),
             args: %{"external_account_id" => account.id}
           )
  end

  test "migrated Microsoft authorization preserves ciphertext and receive references", %{
    mailbox: mailbox
  } do
    receive_method_id = Ecto.UUID.generate()
    address = mailbox |> Repo.preload(:domain) |> Accounts.account_address()
    committed_url = "https://graph.microsoft.test/delta/#{Ecto.UUID.generate()}"
    provider_message_id = "graph-message-#{Ecto.UUID.generate()}"
    token_expires_at = ~U[2026-08-12 02:00:00.000000Z]
    now = ~U[2026-08-12 01:00:00.000000Z]

    assert {:ok, access_token_ciphertext} =
             Crypto.encrypt(
               "legacy-access",
               "credential:#{receive_method_id}:access"
             )

    assert {:ok, refresh_token_ciphertext} =
             Crypto.encrypt(
               "legacy-refresh",
               "credential:#{receive_method_id}:refresh"
             )

    authorization =
      %OAuthAuthorization{id: receive_method_id, lock_version: 6}
      |> OAuthAuthorization.changeset(%{
        account_id: mailbox.id,
        provider: "microsoft",
        provider_subject_id: "graph-user-migrated",
        email_address: address,
        granted_scopes: ["offline_access", "Mail.Read", "Mail.Read"],
        status: "connected",
        key_version: 3,
        access_token_ciphertext: access_token_ciphertext,
        refresh_token_ciphertext: refresh_token_ciphertext,
        token_expires_at: token_expires_at,
        last_error_class: "temporary",
        last_error_code: "legacy_error",
        last_error_message: "legacy provider error"
      })
      |> Repo.insert!()

    receive_method =
      %ReceiveMethod{id: receive_method_id, lock_version: 2}
      |> ReceiveMethod.changeset(%{
        account_id: mailbox.id,
        oauth_authorization_id: authorization.id,
        kind: "microsoft",
        provider_account_id: "graph-user-migrated",
        email_address: address,
        status: "failed",
        enabled: true,
        sync_enabled: true,
        granted_scopes: ["offline_access", "Mail.Read", "Mail.Read"],
        last_error_class: "temporary",
        last_error_code: "legacy_error",
        last_error_message: "legacy provider error"
      })
      |> Repo.insert!()

    cursor =
      %SyncCursor{}
      |> SyncCursor.changeset(%{
        external_account_id: receive_method.id,
        scope: "mailbox",
        phase: "incremental",
        committed_cursor: committed_url,
        metadata: %{"source" => "legacy"},
        generation: 4
      })
      |> Repo.insert!()

    remote =
      %RemoteMessage{}
      |> RemoteMessage.changeset(
        remote_attrs(receive_method.id, provider_message_id, now, %{state: "imported"})
      )
      |> Repo.insert!()

    job =
      %{"external_account_id" => receive_method.id}
      |> SyncAccount.new()
      |> Repo.insert!()

    for event_type <- ~w(connected token_refreshed) do
      %ConnectorEvent{}
      |> ConnectorEvent.changeset(%{
        oauth_authorization_id: authorization.id,
        event_type: event_type,
        metadata: %{"source" => "legacy"},
        occurred_at: now
      })
      |> Repo.insert!()
    end

    assert authorization.id == receive_method.id
    assert receive_method.oauth_authorization_id == authorization.id
    refute Repo.get_by(Credential, external_account_id: receive_method.id)

    assert Crypto.decrypt(
             authorization.access_token_ciphertext,
             "credential:#{receive_method.id}:access"
           ) == {:ok, "legacy-access"}

    assert Crypto.decrypt(
             authorization.refresh_token_ciphertext,
             "credential:#{receive_method.id}:refresh"
           ) == {:ok, "legacy-refresh"}

    assert authorization.provider == "microsoft"
    assert authorization.provider_subject_id == receive_method.provider_account_id
    assert authorization.email_address == receive_method.email_address
    assert authorization.granted_scopes == ["Mail.Read", "offline_access"]
    assert authorization.status == "connected"
    assert receive_method.status == "failed"
    assert authorization.key_version == 3
    assert authorization.lock_version == 7
    assert authorization.token_expires_at == token_expires_at
    assert authorization.last_error_class == receive_method.last_error_class
    assert authorization.last_error_code == receive_method.last_error_code
    assert authorization.last_error_message == receive_method.last_error_message
    persisted_cursor = Repo.get!(SyncCursor, cursor.id)
    assert persisted_cursor.external_account_id == receive_method.id
    assert persisted_cursor.committed_cursor == committed_url

    persisted_remote = Repo.get!(RemoteMessage, remote.id)
    assert persisted_remote.external_account_id == receive_method.id
    assert persisted_remote.provider_message_id == provider_message_id

    assert Repo.get!(Oban.Job, job.id).args == %{"external_account_id" => receive_method.id}

    assert Enum.all?(Repo.all(ConnectorEvent), fn event ->
             event.oauth_authorization_id == authorization.id and
               is_nil(event.external_account_id)
           end)
  end

  test "failure before initial job rolls back the entire local connection", %{mailbox: mailbox} do
    assert {:error, %{reason: :after_credentials_before_job}} =
             Connectors.complete_authorization("microsoft", "valid-code", consumed(mailbox.id),
               fail_at: :after_credentials_before_job
             )

    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(Credential, :count) == 0
    assert Repo.aggregate(SyncCursor, :count) == 0
    assert Repo.aggregate(ConnectorEvent, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "account list is a public projection without encrypted fields", %{mailbox: mailbox} do
    assert {:ok, account} =
             Connectors.complete_authorization("microsoft", "valid-code", consumed(mailbox.id))

    assert [view] = Connectors.list_accounts()
    assert view.id == account.id
    assert view.kind == "microsoft"
    assert view.email_address == "person@microsoft.example"
    assert view.account_id == mailbox.id
    refute Map.has_key?(Map.from_struct(view), :access_token_ciphertext)
    refute Map.has_key?(Map.from_struct(view), :refresh_token_ciphertext)
    assert Connectors.configured_providers() == ["microsoft"]
  end

  test "reauthorization cannot silently move an existing provider account", %{
    domain: domain,
    mailbox: mailbox
  } do
    assert {:ok, account} =
             Connectors.complete_authorization("microsoft", "valid-code", consumed(mailbox.id))

    {:ok, other_mailbox} = Accounts.create_account(domain, %{local_part: "other"})

    assert {:error, %{class: :permanent, reason: :mailbox_reassignment_not_allowed}} =
             Connectors.complete_authorization(
               "microsoft",
               "valid-code",
               consumed(other_mailbox.id)
             )

    persisted = Repo.get!(ReceiveMethod, account.id)
    assert persisted.account_id == mailbox.id
    assert Repo.aggregate(ReceiveMethod, :count) == 1
  end

  test "sync enqueue is unique and disconnect invalidates credentials", %{mailbox: mailbox} do
    assert {:ok, account} =
             Connectors.complete_authorization("microsoft", "valid-code", consumed(mailbox.id))

    assert {:ok, _job} = Connectors.enqueue_sync(account.id)
    assert {:ok, _job} = Connectors.enqueue_sync(account.id)

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == ^inspect(SyncAccount) and
                   fragment("?->>'external_account_id' = ?", job.args, ^account.id)
             ),
             :count
           ) == 1

    assert {:ok, disconnected} = Connectors.disconnect(account.id)
    assert disconnected.status == "disconnected"
    refute disconnected.sync_enabled
    assert is_nil(Repo.get_by(Credential, external_account_id: account.id))

    assert {:error, %{class: :permanent, reason: :account_disconnected}} =
             Connectors.enqueue_sync(account.id)
  end

  test "delete_receive_method removes the method and pending sync jobs", %{mailbox: mailbox} do
    assert {:ok, account} =
             Connectors.complete_authorization("microsoft", "valid-code", consumed(mailbox.id))

    assert {:ok, _job} = Connectors.enqueue_sync(account.id)

    assert {:ok, deleted} = Connectors.delete_receive_method(account.id)
    assert deleted.id == account.id
    assert is_nil(Repo.get(ReceiveMethod, account.id))

    assert Repo.aggregate(
             from(job in Oban.Job,
               where:
                 job.worker == ^inspect(SyncAccount) and
                   fragment("?->>'external_account_id' = ?", job.args, ^account.id)
             ),
             :count
           ) == 0
  end

  test "provider message IDs are case-sensitive", %{mailbox: mailbox} do
    assert {:ok, account} =
             Connectors.complete_authorization("microsoft", "valid-code", consumed(mailbox.id))

    now = DateTime.utc_now()

    Repo.insert!(RemoteMessage.changeset(%RemoteMessage{}, remote_attrs(account.id, "AbC", now)))
    Repo.insert!(RemoteMessage.changeset(%RemoteMessage{}, remote_attrs(account.id, "abc", now)))

    assert Repo.aggregate(RemoteMessage, :count) == 2
  end

  test "remote Sent state places an imported message in Sent", %{
    domain: domain,
    mailbox: mailbox
  } do
    delivery_id = Ecto.UUID.generate()
    insert_delivery(delivery_id, domain.id)
    method = insert_receive_method(mailbox.id, "sent-state")

    remote =
      Repo.insert!(
        RemoteMessage.changeset(
          %RemoteMessage{},
          remote_attrs(method.id, "sent-state", DateTime.utc_now(), %{
            inbound_delivery_id: delivery_id,
            remote_folder_kind: "sent",
            state: "imported"
          })
        )
      )

    assert {:ok, folders} = Mail.list_folders(mailbox.id)
    inbox = Enum.find(folders, &(&1.kind == "inbox"))
    sent = Enum.find(folders, &(&1.kind == "sent"))
    entry = insert_projected_entry(mailbox.id, delivery_id, inbox.id)

    assert :ok = Connectors.apply_remote_state(remote.id)
    assert Repo.get!(MailboxEntry, entry.id).folder_id == sent.id
  end

  test "polling recreates missing sync work without duplicating jobs", %{mailbox: mailbox} do
    assert {:ok, account} =
             Connectors.complete_authorization("microsoft", "valid-code", consumed(mailbox.id))

    Repo.delete_all(Oban.Job)

    assert :ok = PollAccounts.perform(%Oban.Job{args: %{}})
    assert :ok = PollAccounts.perform(%Oban.Job{args: %{}})

    query =
      from(job in Oban.Job,
        where:
          job.worker == ^inspect(SyncAccount) and
            fragment("?->>'external_account_id' = ?", job.args, ^account.id)
      )

    assert Repo.aggregate(query, :count) == 1

    assert {:ok, _account} = Connectors.disconnect(account.id)
    Repo.delete_all(Oban.Job)
    assert :ok = PollAccounts.perform(%Oban.Job{args: %{}})
    assert Repo.aggregate(query, :count) == 0
  end

  test "read push rejects disabled and purging mailboxes without local changes", %{
    domain: domain,
    mailbox: mailbox
  } do
    {:ok, purging_mailbox} = Accounts.create_account(domain, %{local_part: "read-purge"})

    fixtures = [
      {:disabled, mailbox, insert_read_push_fixture(mailbox, domain.id, "disabled")},
      {:purging, purging_mailbox, insert_read_push_fixture(purging_mailbox, domain.id, "purging")}
    ]

    Enum.each(fixtures, fn
      {:disabled, target, _fixture} ->
        assert {:ok, _disabled} = Accounts.disable_account(target.id)

      {:purging, target, _fixture} ->
        {1, nil} =
          Account
          |> where([account], account.id == ^target.id)
          |> Repo.update_all(set: [active: true, purge_requested_at: DateTime.utc_now()])
    end)

    Enum.each(fixtures, fn {_state, _target, %{entry: entry, remote: remote}} ->
      assert_mailbox_not_active(fn -> Connectors.enqueue_read_push([entry.id], true) end)
      refute Repo.get!(RemoteMessage, remote.id).remote_read

      refute Repo.exists?(
               from(job in Oban.Job,
                 where:
                   job.worker == ^inspect(PushRemoteRead) and
                     fragment("?->>'remote_message_id' = ?", job.args, ^remote.id)
               )
             )
    end)
  end

  test "read push only updates the mailbox entry owner's remote on a shared delivery", %{
    domain: domain,
    mailbox: purging_mailbox
  } do
    {:ok, active_mailbox} = Accounts.create_account(domain, %{local_part: "read-shared-active"})
    delivery_id = Ecto.UUID.generate()
    insert_delivery(delivery_id, domain.id)

    purging_method =
      insert_receive_method(purging_mailbox.id, "read-shared-purging", kind: "imap")

    active_method = insert_receive_method(active_mailbox.id, "read-shared-active", kind: "imap")

    purging_remote =
      insert_remote_message(purging_method.id, "read-shared-purging", delivery_id)

    active_remote = insert_remote_message(active_method.id, "read-shared-active", delivery_id)

    entry =
      Repo.insert!(
        MailboxEntry.changeset(%MailboxEntry{}, %{
          mailbox_id: active_mailbox.id,
          inbound_delivery_id: delivery_id,
          original_recipient: "read-shared-active@example.test",
          quarantined: false
        })
      )

    {1, nil} =
      Account
      |> where([account], account.id == ^purging_mailbox.id)
      |> Repo.update_all(set: [active: true, purge_requested_at: DateTime.utc_now()])

    assert :ok = Connectors.enqueue_read_push([entry.id], true)

    assert Repo.get!(RemoteMessage, active_remote.id).remote_read
    refute Repo.get!(RemoteMessage, purging_remote.id).remote_read

    assert Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == ^inspect(PushRemoteRead) and
                   fragment("?->>'remote_message_id' = ?", job.args, ^active_remote.id)
             )
           )

    refute Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == ^inspect(PushRemoteRead) and
                   fragment("?->>'remote_message_id' = ?", job.args, ^purging_remote.id)
             )
           )
  end

  test "sync_job_running? reflects incomplete SyncAccount jobs", %{mailbox: mailbox} do
    assert {:ok, account} =
             Connectors.complete_authorization("microsoft", "valid-code", consumed(mailbox.id))

    # OAuth completion enqueues SyncAccount; clear so we assert from a known empty state
    Repo.delete_all(Oban.Job)
    refute Connectors.sync_job_running?(account.id)

    assert {:ok, _job} = Connectors.enqueue_sync(account.id)
    assert Connectors.sync_job_running?(account.id)

    {count, _} =
      Oban.Job
      |> where([job], job.worker == ^inspect(Manifold.Connectors.Jobs.SyncAccount))
      |> where(
        [job],
        fragment("?->>'external_account_id' = ?", job.args, ^account.id)
      )
      |> Repo.update_all(set: [state: "completed"])

    assert count >= 1
    refute Connectors.sync_job_running?(account.id)
  end

  test "quiesce_account disables all local methods in the caller transaction without deleting state",
       %{
         mailbox: mailbox
       } do
    assert {:ok, receive} =
             Connectors.complete_authorization("microsoft", "valid-code", consumed(mailbox.id))

    assert {:ok, placeholder} =
             Connectors.create_placeholder_receive_method(mailbox.id, "pop3")

    assert {:ok, send_method} = create_smtp_method(mailbox)

    assert {:error, :rollback} =
             Repo.transaction(fn ->
               assert {:ok, %{receive_methods: 2, send_methods: 1}} =
                        Connectors.quiesce_account(Repo, mailbox.id)

               refute Repo.get!(ReceiveMethod, receive.id).enabled
               refute Repo.get!(ReceiveMethod, receive.id).sync_enabled
               refute Repo.get!(SendMethod, send_method.id).enabled
               Repo.rollback(:rollback)
             end)

    assert Repo.get!(ReceiveMethod, receive.id).enabled
    assert Repo.get!(ReceiveMethod, receive.id).sync_enabled
    assert Repo.get!(SendMethod, send_method.id).enabled

    assert {:ok, {:ok, %{receive_methods: 2, send_methods: 1}}} =
             Repo.transaction(fn -> Connectors.quiesce_account(Repo, mailbox.id) end)

    for method <- Repo.all(from(method in ReceiveMethod, where: method.account_id == ^mailbox.id)) do
      refute method.enabled
      refute method.sync_enabled
    end

    refute Repo.get!(SendMethod, send_method.id).enabled
    assert Repo.get_by!(Credential, external_account_id: receive.id)
    assert Repo.get_by!(SendCredential, send_method_id: send_method.id)
    assert Repo.get_by!(SmtpSettings, send_method_id: send_method.id)
    assert Repo.get!(ReceiveMethod, placeholder.id)
  end

  test "connector persistence and scheduling reject inactive and purging mailboxes", %{
    mailbox: mailbox
  } do
    receive = insert_receive_method(mailbox.id, "manual", enabled: true, sync_enabled: true)

    assert {:ok, placeholder} =
             Connectors.create_placeholder_receive_method(mailbox.id, "pop3")

    send_method = insert_send_method(mailbox.id, enabled: true)
    assert {:ok, _disabled} = Accounts.disable_account(mailbox.id)

    assert_mailbox_not_active(fn ->
      Connectors.complete_authorization("microsoft", "valid-code", consumed(mailbox.id))
    end)

    assert_mailbox_not_active(fn ->
      Connectors.create_placeholder_receive_method(mailbox.id, "pop3")
    end)

    assert_mailbox_not_active(fn ->
      Connectors.create_imap_account(%{
        account_id: mailbox.id,
        email_address: "inactive-imap@example.test",
        username: "inactive-imap@example.test",
        password: "secret",
        host: "imap.example.test",
        port: 993,
        tls_mode: "tls",
        skip_test: true
      })
    end)

    assert_mailbox_not_active(fn ->
      Connectors.create_eas_account(%{
        account_id: mailbox.id,
        email_address: "inactive-eas@example.test",
        username: "inactive-eas@example.test",
        password: "secret",
        host: "eas.example.test",
        port: 443
      })
    end)

    assert_mailbox_not_active(fn ->
      address = mailbox |> Repo.preload(:domain) |> Accounts.account_address()

      Connectors.create_smtp_send_method(%{
        account_id: mailbox.id,
        email_address: address,
        username: address,
        password: "secret",
        host: "smtp.example.test",
        port: 465,
        tls_mode: "tls",
        skip_test: true
      })
    end)

    assert_mailbox_not_active(fn -> Connectors.enable_receive_method(receive.id) end)
    assert_mailbox_not_active(fn -> Connectors.enable_receive_method(placeholder.id) end)

    assert_mailbox_not_active(fn ->
      Connectors.enable_send_method(mailbox.id, send_method.id)
    end)

    assert_mailbox_not_active(fn -> Connectors.enqueue_sync(receive.id) end)

    assert {:ok, {:ok, _counts}} =
             Repo.transaction(fn -> Connectors.quiesce_account(Repo, mailbox.id) end)

    assert_mailbox_not_active(fn -> Connectors.enqueue_sync(receive.id) end)

    Repo.delete_all(Oban.Job)
    assert {:ok, 0} = Connectors.enqueue_due_syncs()
    refute Repo.exists?(from(job in Oban.Job, where: job.worker == ^inspect(SyncAccount)))

    {1, nil} =
      Account
      |> where([account], account.id == ^mailbox.id)
      |> Repo.update_all(set: [active: true, purge_requested_at: DateTime.utc_now()])

    assert_mailbox_not_active(fn ->
      Connectors.create_placeholder_receive_method(mailbox.id, "ews")
    end)

    assert Repo.aggregate(ReceiveMethod, :count) == 2
    assert Repo.aggregate(SendMethod, :count) == 1
  end

  test "cancel_account_jobs is bounded and matches only account worker arguments", %{
    domain: domain,
    mailbox: mailbox
  } do
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})

    target_methods =
      for suffix <- ~w(one two three) do
        insert_receive_method(mailbox.id, suffix)
      end

    target_remotes =
      for {method, suffix} <- Enum.zip(Enum.take(target_methods, 2), ~w(one two)) do
        insert_remote_message(method.id, suffix)
      end

    {:ok, other_mailbox} = Accounts.create_account(domain, %{local_part: "job-other"})
    other_method = insert_receive_method(other_mailbox.id, "other")
    other_remote = insert_remote_message(other_method.id, "other")

    Enum.each(target_methods, fn method ->
      method.id |> then(&SyncAccount.new(%{"external_account_id" => &1})) |> Repo.insert!()
    end)

    Enum.each(target_remotes, fn remote ->
      remote.id |> then(&ApplyRemoteState.new(%{"remote_message_id" => &1})) |> Repo.insert!()

      %{"remote_message_id" => remote.id, "read" => true}
      |> PushRemoteRead.new()
      |> Repo.insert!()
    end)

    other_method.id
    |> then(&SyncAccount.new(%{"external_account_id" => &1}))
    |> Repo.insert!()

    other_remote.id
    |> then(&ApplyRemoteState.new(%{"remote_message_id" => &1}))
    |> Repo.insert!()

    PollAccounts.new(%{"external_account_id" => hd(target_methods).id}) |> Repo.insert!()

    results = for _ <- 1..4, do: Connectors.cancel_account_jobs(mailbox.id, 2)
    assert Enum.map(results, & &1.cancelled) == [2, 2, 2, 1]
    assert Enum.all?(results, &(&1.cancelled <= 2))
    assert Enum.map(results, & &1.done?) == [false, false, false, true]

    assert Repo.get_by!(Oban.Job,
             worker: inspect(SyncAccount),
             args: %{"external_account_id" => other_method.id}
           ).state == "available"

    assert Repo.get_by!(Oban.Job,
             worker: inspect(ApplyRemoteState),
             args: %{"remote_message_id" => other_remote.id}
           ).state == "available"

    assert Repo.get_by!(Oban.Job, worker: inspect(PollAccounts)).state == "available"

    executing =
      hd(target_methods).id
      |> then(&SyncAccount.new(%{"external_account_id" => &1}))
      |> Repo.insert!()

    {1, nil} =
      Oban.Job
      |> where([job], job.id == ^executing.id)
      |> Repo.update_all(set: [state: "executing"])

    assert {:snooze, 5} = Connectors.cancel_account_jobs(mailbox.id, 2)
    assert Repo.get!(Oban.Job, executing.id).state == "cancelled"
    assert %{cancelled: 0, done?: true} = Connectors.cancel_account_jobs(mailbox.id, 2)
  end

  test "cancel_account_jobs treats suspended matching jobs as incomplete", %{mailbox: mailbox} do
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})
    method = insert_receive_method(mailbox.id, "suspended")

    job =
      method.id
      |> then(&SyncAccount.new(%{"external_account_id" => &1}))
      |> Repo.insert!()

    {1, nil} =
      Oban.Job
      |> where([candidate], candidate.id == ^job.id)
      |> Repo.update_all(set: [state: "suspended"])

    assert %{cancelled: 1, done?: true} = Connectors.cancel_account_jobs(mailbox.id, 10)
    assert Repo.get!(Oban.Job, job.id).state == "cancelled"
  end

  test "cancel_account_jobs keeps account ownership matching inside the job query", %{
    mailbox: mailbox
  } do
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})

    [target_method | _] =
      for index <- 1..25 do
        method = insert_receive_method(mailbox.id, "query-shape-#{index}")
        insert_remote_message(method.id, "query-shape-#{index}")
        method
      end

    valid_job =
      target_method.id
      |> then(&SyncAccount.new(%{"external_account_id" => &1}))
      |> Repo.insert!()

    malformed_jobs = [
      SyncAccount.new(%{"external_account_id" => "not-a-uuid"}) |> Repo.insert!(),
      ApplyRemoteState.new(%{"remote_message_id" => "also-not-a-uuid"}) |> Repo.insert!(),
      PushRemoteRead.new(%{"remote_message_id" => "still-not-a-uuid", "read" => true})
      |> Repo.insert!()
    ]

    {result, queries} =
      capture_repo_queries(fn -> Connectors.cancel_account_jobs(mailbox.id, 10) end)

    assert %{cancelled: 1, done?: true} = result
    assert Repo.get!(Oban.Job, valid_job.id).state == "cancelled"
    assert Enum.all?(malformed_jobs, &(Repo.get!(Oban.Job, &1.id).state == "available"))

    ownership_queries = Enum.filter(queries, &String.contains?(&1, "connector_accounts"))
    assert ownership_queries != []

    assert Enum.all?(ownership_queries, &String.contains?(&1, "oban_jobs"))
    refute Enum.any?(ownership_queries, &String.contains?(&1, "receive_method.id::text"))
    refute Enum.any?(ownership_queries, &String.contains?(&1, "remote_message.id::text"))

    assert Enum.any?(ownership_queries, fn query ->
             String.contains?(query, "receive_method.id = CASE") and
               String.contains?(query, "remote_message.id = CASE")
           end)
  end

  test "delivery discovery is distinct, UUID ordered, account scoped, and ownership aware", %{
    domain: domain,
    mailbox: mailbox
  } do
    method = insert_receive_method(mailbox.id, "deliveries")
    delivery_ids = Enum.sort(for _ <- 1..3, do: Ecto.UUID.generate())
    Enum.each(delivery_ids, &insert_delivery(&1, domain.id))

    insert_remote_message(method.id, "delivery-one", Enum.at(delivery_ids, 2))
    insert_remote_message(method.id, "delivery-two", Enum.at(delivery_ids, 0))
    insert_remote_message(method.id, "delivery-three", Enum.at(delivery_ids, 1))
    insert_remote_message(method.id, "delivery-duplicate", Enum.at(delivery_ids, 1))
    insert_remote_message(method.id, "delivery-nil")

    assert %{ids: first, next: cursor, done?: false} =
             Connectors.list_account_delivery_ids(mailbox.id, nil, 2)

    assert first == Enum.take(delivery_ids, 2)
    assert cursor == Enum.at(delivery_ids, 1)

    assert %{ids: [last], next: next, done?: true} =
             Connectors.list_account_delivery_ids(mailbox.id, cursor, 2)

    assert last == List.last(delivery_ids)
    assert next == last

    assert %{ids: [], next: nil, done?: true} =
             Connectors.list_account_delivery_ids(mailbox.id, last, 2)

    assert Enum.all?(delivery_ids, &Connectors.delivery_owned?/1)
    refute Connectors.delivery_owned?(Ecto.UUID.generate())
  end

  test "purge_account_batch removes one bounded local class at a time and preserves other accounts",
       %{
         domain: domain,
         mailbox: mailbox
       } do
    target_methods =
      for suffix <- ~w(purge-one purge-two), do: insert_receive_method(mailbox.id, suffix)

    for {suffix, method} <- Enum.zip(~w(a b c), Stream.cycle(target_methods)) do
      insert_remote_message(method.id, "purge-#{suffix}")
    end

    target_send = insert_send_method(mailbox.id)
    target_oauth = for suffix <- ~w(a b), do: insert_oauth_transaction(mailbox.id, suffix)

    {:ok, other_mailbox} = Accounts.create_account(domain, %{local_part: "purge-other"})
    other_method = insert_receive_method(other_mailbox.id, "purge-other")
    other_remote = insert_remote_message(other_method.id, "purge-other")
    other_send = insert_send_method(other_mailbox.id)
    other_oauth = insert_oauth_transaction(other_mailbox.id, "other")

    assert Connectors.account_data_remaining?(mailbox.id)

    assert {:ok, first} =
             Repo.transaction(fn -> Connectors.purge_account_batch(Repo, mailbox.id, 2) end)

    assert %{deleted: 2, done?: false, activity_log_ids: []} = first

    assert Repo.aggregate(
             from(r in RemoteMessage,
               join: m in ReceiveMethod,
               on: m.id == r.external_account_id,
               where: m.account_id == ^mailbox.id
             ),
             :count
           ) == 1

    assert Repo.aggregate(from(m in ReceiveMethod, where: m.account_id == ^mailbox.id), :count) ==
             2

    assert {:ok, %{deleted: 1, done?: false, activity_log_ids: []}} =
             Repo.transaction(fn -> Connectors.purge_account_batch(Repo, mailbox.id, 2) end)

    assert {:ok, receive_batch} =
             Repo.transaction(fn -> Connectors.purge_account_batch(Repo, mailbox.id, 2) end)

    assert receive_batch.deleted == 2
    assert receive_batch.done? == false

    assert Enum.sort(receive_batch.activity_log_ids) ==
             Enum.sort(Enum.map(target_methods, & &1.id))

    assert {:ok, %{deleted: 1, done?: false, activity_log_ids: []}} =
             Repo.transaction(fn -> Connectors.purge_account_batch(Repo, mailbox.id, 2) end)

    assert is_nil(Repo.get(SendMethod, target_send.id))

    assert {:ok, %{deleted: 2, done?: true, activity_log_ids: []}} =
             Repo.transaction(fn -> Connectors.purge_account_batch(Repo, mailbox.id, 2) end)

    assert Enum.all?(target_oauth, &is_nil(Repo.get(OAuthTransaction, &1.id)))
    refute Connectors.account_data_remaining?(mailbox.id)

    assert Repo.get!(ReceiveMethod, other_method.id)
    assert Repo.get!(RemoteMessage, other_remote.id)
    assert Repo.get!(SendMethod, other_send.id)
    assert Repo.get!(OAuthTransaction, other_oauth.id)
  end

  defp consumed(mailbox_id) do
    %Consumed{
      provider: "microsoft",
      mailbox_id: mailbox_id,
      redirect_uri: "https://mail.example.test/connectors/microsoft/callback",
      pkce_verifier: "verifier"
    }
  end

  defp remote_attrs(account_id, message_id, now, overrides \\ %{}) do
    Map.merge(
      %{
        external_account_id: account_id,
        provider_message_id: message_id,
        remote_labels: [],
        remote_read: false,
        remote_starred: false,
        remote_deleted: false,
        state: "pending",
        synced_at: now
      },
      overrides
    )
  end

  defp create_smtp_method(mailbox) do
    address = mailbox |> Repo.preload(:domain) |> Accounts.account_address()

    Connectors.create_smtp_send_method(%{
      account_id: mailbox.id,
      email_address: address,
      username: address,
      password: "secret",
      host: "smtp.example.test",
      port: 465,
      tls_mode: "tls",
      skip_test: true
    })
  end

  defp insert_receive_method(mailbox_id, suffix, opts \\ []) do
    Repo.insert!(
      ReceiveMethod.changeset(%ReceiveMethod{}, %{
        account_id: mailbox_id,
        kind: Keyword.get(opts, :kind, "gmail"),
        provider_account_id: "#{suffix}:#{Ecto.UUID.generate()}",
        email_address: "#{suffix}@example.test",
        status: "connected",
        enabled: Keyword.get(opts, :enabled, false),
        sync_enabled: Keyword.get(opts, :sync_enabled, false),
        granted_scopes: []
      })
    )
  end

  defp insert_send_method(mailbox_id, opts \\ []) do
    Repo.insert!(
      SendMethod.changeset(%SendMethod{}, %{
        account_id: mailbox_id,
        kind: "smtp",
        email_address: "#{Ecto.UUID.generate()}@example.test",
        status: "connected",
        enabled: Keyword.get(opts, :enabled, false)
      })
    )
  end

  defp insert_remote_message(method_id, suffix, delivery_id \\ nil) do
    Repo.insert!(
      RemoteMessage.changeset(
        %RemoteMessage{},
        remote_attrs(method_id, suffix, DateTime.utc_now(), %{inbound_delivery_id: delivery_id})
      )
    )
  end

  defp insert_oauth_transaction(mailbox_id, suffix) do
    Repo.insert!(
      OAuthTransaction.changeset(%OAuthTransaction{}, %{
        state_digest: :crypto.hash(:sha256, "#{suffix}:#{Ecto.UUID.generate()}"),
        provider: "gmail",
        mailbox_id: mailbox_id,
        pkce_verifier_ciphertext: "ciphertext",
        redirect_uri: "https://example.test/callback",
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      })
    )
  end

  defp insert_delivery(delivery_id, domain_id) do
    now = DateTime.utc_now()

    {1, nil} =
      Repo.insert_all(InboundDelivery, [
        %{
          id: delivery_id,
          ingest_id: "connector-test-#{delivery_id}",
          source_kind: "provider_import",
          storage_domain_id: domain_id,
          received_at: now,
          raw_size: 1,
          raw_sha256: String.duplicate("0", 64),
          spool_bundle_path: "/tmp/#{delivery_id}",
          raw_storage_state: "spooled",
          processing_state: "accepted",
          inserted_at: now,
          updated_at: now
        }
      ])
  end

  defp insert_projected_entry(mailbox_id, delivery_id, folder_id) do
    now = DateTime.utc_now()

    message =
      Repo.insert!(
        Message.changeset(%Message{}, %{
          inbound_delivery_id: delivery_id,
          subject: "Sent state",
          sent_at: now,
          parser_version: 1,
          sanitizer_version: 1,
          parse_state: "parsed"
        })
      )

    thread =
      Repo.insert!(
        Thread.changeset(%Thread{}, %{
          mailbox_id: mailbox_id,
          subject_summary: "Sent state",
          last_message_at: now,
          message_count: 1
        })
      )

    Repo.insert!(
      MailboxEntry.changeset(%MailboxEntry{}, %{
        mailbox_id: mailbox_id,
        inbound_delivery_id: delivery_id,
        message_id: message.id,
        folder_id: folder_id,
        thread_id: thread.id,
        original_recipient: "person@example.test",
        quarantined: false
      })
    )
  end

  defp insert_read_push_fixture(mailbox, domain_id, suffix) do
    delivery_id = Ecto.UUID.generate()
    insert_delivery(delivery_id, domain_id)
    method = insert_receive_method(mailbox.id, "read-push-#{suffix}", kind: "imap")
    remote = insert_remote_message(method.id, "read-push-#{suffix}", delivery_id)

    entry =
      Repo.insert!(
        MailboxEntry.changeset(%MailboxEntry{}, %{
          mailbox_id: mailbox.id,
          inbound_delivery_id: delivery_id,
          original_recipient: "#{suffix}@example.test",
          quarantined: false
        })
      )

    %{entry: entry, remote: remote}
  end

  defp capture_repo_queries(fun) do
    event = Keyword.fetch!(Repo.config(), :telemetry_prefix) ++ [:query]
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, metadata, pid -> send(pid, {:repo_query, metadata.query}) end,
        self()
      )

    try do
      result = fun.()
      {result, collect_repo_queries([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_repo_queries(queries) do
    receive do
      {:repo_query, query} -> collect_repo_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp assert_mailbox_not_active(fun) do
    assert {:error, %{class: :permanent, reason: :mailbox_not_active}} = fun.()
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

defmodule Manifold.ConnectorsPollingRaceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Manifold.Accounts
  alias Manifold.Accounts.Schema.{Account, Domain}
  alias Manifold.Connectors
  alias Manifold.Connectors.Jobs.SyncAccount
  alias Manifold.Connectors.Schema.ReceiveMethod
  alias Manifold.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    suffix = System.unique_integer([:positive])

    domain =
      Repo.insert!(
        Domain.changeset(%Domain{}, %{
          name: "connector-race-#{suffix}.test",
          active: true
        })
      )

    mailbox =
      Repo.insert!(
        Account.changeset(%Account{}, %{
          domain_id: domain.id,
          local_part: "poll-race",
          active: true
        })
      )

    method =
      Repo.insert!(
        ReceiveMethod.changeset(%ReceiveMethod{}, %{
          account_id: mailbox.id,
          kind: "gmail",
          provider_account_id: "poll-race:#{Ecto.UUID.generate()}",
          email_address: "poll-race@example.test",
          status: "connected",
          enabled: true,
          sync_enabled: true,
          granted_scopes: []
        })
      )

    on_exit(fn -> cleanup_fixture(domain.id, mailbox.id, method.id) end)

    {:ok, mailbox: mailbox, method: method}
  end

  test "polling waits for a concurrent mailbox transition and rechecks activity", %{
    mailbox: mailbox,
    method: method
  } do
    test_process = self()

    poller =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          Connectors.enqueue_due_syncs(
            before_locked_recheck: fn ->
              %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(test_process, {:poll_candidates_discovered, self(), backend_pid})

              receive do
                :attempt_mailbox_lock -> :ok
              end
            end
          )
        after
          Sandbox.checkin(Repo)
        end
      end)

    poller_pid = poller.pid
    assert_receive {:poll_candidates_discovered, ^poller_pid, poller_backend_pid}, 5_000

    disabler =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo, sandbox: false)

        try do
          Repo.transaction(fn ->
            assert {:ok, disabled} = Accounts.disable_account(Repo, mailbox.id)
            send(test_process, {:mailbox_disabled_and_locked, self()})

            receive do
              :commit_mailbox_disable -> disabled
            end
          end)
        after
          Sandbox.checkin(Repo)
        end
      end)

    disabler_pid = disabler.pid
    assert_receive {:mailbox_disabled_and_locked, ^disabler_pid}, 5_000
    send(poller_pid, :attempt_mailbox_lock)
    assert_postgres_lock_wait(poller_backend_pid)

    send(disabler_pid, :commit_mailbox_disable)
    assert {:ok, %Account{active: false}} = Task.await(disabler)
    assert {:ok, 0} = Task.await(poller)

    refute Repo.exists?(
             from(job in Oban.Job,
               where:
                 job.worker == ^inspect(SyncAccount) and
                   fragment("?->>'external_account_id' = ?", job.args, ^method.id)
             )
           )
  end

  defp assert_postgres_lock_wait(backend_pid, attempts \\ 500)

  defp assert_postgres_lock_wait(_backend_pid, 0) do
    flunk("polling transaction never blocked on the mailbox row lock")
  end

  defp assert_postgres_lock_wait(backend_pid, attempts) do
    wait_event =
      Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid])
      |> Map.fetch!(:rows)

    if wait_event == [["Lock"]] do
      :ok
    else
      Process.sleep(10)
      assert_postgres_lock_wait(backend_pid, attempts - 1)
    end
  end

  defp cleanup_fixture(domain_id, mailbox_id, method_id) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      Repo.delete_all(
        from(job in Oban.Job,
          where:
            job.worker == ^inspect(SyncAccount) and
              fragment("?->>'external_account_id' = ?", job.args, ^method_id)
        )
      )

      Repo.delete_all(from(method in ReceiveMethod, where: method.id == ^method_id))
      Repo.delete_all(from(mailbox in Account, where: mailbox.id == ^mailbox_id))
      Repo.delete_all(from(domain in Domain, where: domain.id == ^domain_id))
    after
      Sandbox.checkin(Repo)
    end
  end
end

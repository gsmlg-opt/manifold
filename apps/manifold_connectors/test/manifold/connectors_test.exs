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

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    Credential,
    OAuthTransaction,
    ReceiveMethod,
    RemoteMessage,
    SendCredential,
    SendMethod,
    SmtpSettings,
    SyncCursor
  }

  alias Manifold.Repo

  defmodule FakeGmail do
    @behaviour Manifold.Connectors.Provider

    @impl true
    def exchange_code("valid-code", "verifier", _redirect_uri, _config, _opts) do
      {:ok,
       %Token{
         access_token: "access-secret",
         refresh_token: "refresh-secret",
         expires_at: ~U[2026-07-29 02:00:00.000000Z],
         scopes: ["openid", "email", "https://www.googleapis.com/auth/gmail.readonly"]
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
      {:ok, %Identity{id: "google-subject-1", email_address: "person@gmail.example"}}
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

    Application.put_env(:manifold_connectors, :adapters, gmail: FakeGmail)
    Application.put_env(:manifold_connectors, :eas_transport, EasFake)

    Application.put_env(:manifold_connectors, :eas_fake, %{
      password_expected: "secret",
      messages: []
    })

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
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
             Connectors.complete_authorization("gmail", "valid-code", consumed,
               now: ~U[2026-07-29 01:00:00.000000Z]
             )

    assert account.kind == "gmail"
    assert account.provider_account_id == "google-subject-1"
    assert account.email_address == "person@gmail.example"
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

    assert Repo.get_by!(ConnectorEvent,
             external_account_id: account.id,
             event_type: "connected"
           )

    assert Repo.get_by!(Oban.Job,
             worker: inspect(SyncAccount),
             args: %{"external_account_id" => account.id}
           )
  end

  test "failure before initial job rolls back the entire local connection", %{mailbox: mailbox} do
    assert {:error, %{reason: :after_credentials_before_job}} =
             Connectors.complete_authorization("gmail", "valid-code", consumed(mailbox.id),
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
             Connectors.complete_authorization("gmail", "valid-code", consumed(mailbox.id))

    assert [view] = Connectors.list_accounts()
    assert view.id == account.id
    assert view.kind == "gmail"
    assert view.email_address == "person@gmail.example"
    assert view.account_id == mailbox.id
    refute Map.has_key?(Map.from_struct(view), :access_token_ciphertext)
    refute Map.has_key?(Map.from_struct(view), :refresh_token_ciphertext)
    assert Connectors.configured_providers() == ["gmail"]
  end

  test "reauthorization cannot silently move an existing provider account", %{
    domain: domain,
    mailbox: mailbox
  } do
    assert {:ok, account} =
             Connectors.complete_authorization("gmail", "valid-code", consumed(mailbox.id))

    {:ok, other_mailbox} = Accounts.create_account(domain, %{local_part: "other"})

    assert {:error, %{class: :permanent, reason: :mailbox_reassignment_not_allowed}} =
             Connectors.complete_authorization(
               "gmail",
               "valid-code",
               consumed(other_mailbox.id)
             )

    persisted = Repo.get!(ReceiveMethod, account.id)
    assert persisted.account_id == mailbox.id
    assert Repo.aggregate(ReceiveMethod, :count) == 1
  end

  test "sync enqueue is unique and disconnect invalidates credentials", %{mailbox: mailbox} do
    assert {:ok, account} =
             Connectors.complete_authorization("gmail", "valid-code", consumed(mailbox.id))

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
             Connectors.complete_authorization("gmail", "valid-code", consumed(mailbox.id))

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
             Connectors.complete_authorization("gmail", "valid-code", consumed(mailbox.id))

    now = DateTime.utc_now()

    Repo.insert!(RemoteMessage.changeset(%RemoteMessage{}, remote_attrs(account.id, "AbC", now)))
    Repo.insert!(RemoteMessage.changeset(%RemoteMessage{}, remote_attrs(account.id, "abc", now)))

    assert Repo.aggregate(RemoteMessage, :count) == 2
  end

  test "polling recreates missing sync work without duplicating jobs", %{mailbox: mailbox} do
    assert {:ok, account} =
             Connectors.complete_authorization("gmail", "valid-code", consumed(mailbox.id))

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

  test "sync_job_running? reflects incomplete SyncAccount jobs", %{mailbox: mailbox} do
    assert {:ok, account} =
             Connectors.complete_authorization("gmail", "valid-code", consumed(mailbox.id))

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
             Connectors.complete_authorization("gmail", "valid-code", consumed(mailbox.id))

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
      Connectors.complete_authorization("gmail", "valid-code", consumed(mailbox.id))
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
      Connectors.create_smtp_send_method(%{
        account_id: mailbox.id,
        email_address: "inactive-smtp@example.test",
        username: "inactive-smtp@example.test",
        password: "secret",
        host: "smtp.example.test",
        port: 465,
        tls_mode: "tls",
        skip_test: true
      })
    end)

    assert_mailbox_not_active(fn -> Connectors.enable_receive_method(receive.id) end)
    assert_mailbox_not_active(fn -> Connectors.enable_receive_method(placeholder.id) end)
    assert_mailbox_not_active(fn -> Connectors.enable_send_method(send_method.id) end)
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
      provider: "gmail",
      mailbox_id: mailbox_id,
      redirect_uri: "https://mail.example.test/connectors/gmail/callback",
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
    Connectors.create_smtp_send_method(%{
      account_id: mailbox.id,
      email_address: "sender@example.test",
      username: "sender@example.test",
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
        kind: "gmail",
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

  defp assert_mailbox_not_active(fun) do
    assert {:error, %{class: :permanent, reason: :mailbox_not_active}} = fun.()
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

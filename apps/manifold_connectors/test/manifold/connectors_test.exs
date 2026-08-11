defmodule Manifold.ConnectorsTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.Jobs.{PollAccounts, SyncAccount}
  alias Manifold.Connectors.OAuth.Consumed
  alias Manifold.Connectors.Provider.{Identity, Page, RawMessage, Token}
  alias Manifold.Connectors.Provider.SyncCursor, as: ProviderCursor

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    Credential,
    ReceiveMethod,
    SyncCursor,
    RemoteMessage
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

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :adapters, microsoft: FakeMicrosoft)

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

  defp consumed(mailbox_id) do
    %Consumed{
      provider: "microsoft",
      mailbox_id: mailbox_id,
      redirect_uri: "https://mail.example.test/connectors/microsoft/callback",
      pkce_verifier: "verifier"
    }
  end

  defp remote_attrs(account_id, message_id, now) do
    %{
      external_account_id: account_id,
      provider_message_id: message_id,
      remote_labels: [],
      remote_read: false,
      remote_starred: false,
      remote_deleted: false,
      state: "pending",
      synced_at: now
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

defmodule Manifold.Connectors.GmailAuthorizationsTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, GmailScopes}
  alias Manifold.Connectors.Jobs.SyncAccount
  alias Manifold.Connectors.OAuth
  alias Manifold.Connectors.OAuth.Consumed
  alias Manifold.Connectors.Provider.{Identity, Page, RawMessage, Token}
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Connectors.Provider.SyncCursor, as: ProviderCursor
  alias Manifold.Core.Error, as: CoreError

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    Credential,
    OAuthAuthorization,
    OAuthProviderSetting,
    ReceiveMethod,
    SendMethod,
    SyncCursor
  }

  alias Manifold.Repo

  defmodule FakeGmail do
    @behaviour Manifold.Connectors.Provider

    @impl true
    def exchange_code(_code, _verifier, _redirect_uri, config, opts) do
      notify_config(opts, :exchange_config, config)

      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:exchange_required_scopes, Keyword.get(opts, :required_scopes)})
      end

      if gate = Keyword.get(opts, :exchange_gate) do
        test_pid = Keyword.fetch!(opts, :test_pid)
        send(test_pid, {:oauth_code_exchanged, self(), gate})

        receive do
          {:release_oauth_exchange, ^gate} -> :ok
        end
      end

      case Keyword.get(opts, :raise) do
        nil -> Keyword.fetch!(opts, :token)
        exception -> raise exception
      end
    end

    @impl true
    def identity(_access_token, config, opts) do
      notify_config(opts, :identity_config, config)
      Keyword.fetch!(opts, :identity)
    end

    @impl true
    def initial_cursors(_access_token, config, opts) do
      notify_config(opts, :initial_cursors_config, config)

      Keyword.get(opts, :cursors, {:ok, [%ProviderCursor{scope: "mailbox", phase: "initial"}]})
    end

    @impl true
    def refresh_token(refresh_token, config, opts) do
      if counter = Keyword.get(opts, :refresh_count) do
        Agent.update(counter, &(&1 + 1))
      end

      notify_config(opts, :refresh_config, config)

      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:refresh_token, refresh_token})
      end

      if gate = Keyword.get(opts, :refresh_gate) do
        receive do
          {:release_refresh, ^gate} -> :ok
        end
      end

      Keyword.fetch!(opts, :refresh_result)
    end

    defp notify_config(opts, event, config) do
      if test_pid =
           Keyword.get(opts, :test_pid) ||
             Application.get_env(:manifold_connectors, :gmail_authorizations_test_pid) do
        send(test_pid, {event, config})
      end
    end

    @impl true
    def sync_page(_access_token, cursor, _config, _opts), do: {:ok, %Page{cursor: cursor}}

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

    Application.put_env(:manifold_connectors, :adapters, gmail: FakeGmail)

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        client_id: "client",
        client_secret: "secret",
        authorization_url: "https://accounts.google.test/authorize"
      ]
    )

    assert {:ok, _setting_view} =
             Connectors.put_oauth_provider_setting("gmail", %{
               "client_id" => "db-client",
               "client_secret" => "db-secret"
             })

    gmail_setting = Repo.get_by!(OAuthProviderSetting, provider: "gmail")

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:adapters, old_adapters)
      restore_env(:providers, old_providers)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "gmail#{suffix}.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "person"})
    account = Repo.preload(account, :domain)

    {:ok,
     account: account, address: Accounts.account_address(account), gmail_setting: gmail_setting}
  end

  test "unchanged Gmail setting generation completes through the public context", %{
    account: account,
    address: address,
    gmail_setting: gmail_setting
  } do
    consumed = start_and_consume_gmail!(account.id)

    assert consumed.oauth_provider_setting_id == gmail_setting.id
    assert consumed.oauth_provider_setting_lock_version == gmail_setting.lock_version

    assert {:ok, %ReceiveMethod{status: "connected"}} =
             Connectors.complete_authorization("gmail", "authorization-code", consumed,
               now: ~U[2026-08-11 01:00:00.000000Z],
               provider_opts: completion_provider_opts(address, test_pid: self())
             )

    assert_receive {:exchange_config, config}
    assert_receive {:identity_config, ^config}
    assert config[:client_id] == "db-client"
    assert config[:client_secret] == "db-secret"
  end

  test "legacy Gmail completion fences the resolved generation across code exchange", %{
    account: account,
    address: address,
    gmail_setting: gmail_setting
  } do
    consumed =
      account.id
      |> start_and_consume_gmail!()
      |> Map.put(:oauth_provider_setting_id, nil)
      |> Map.put(:oauth_provider_setting_lock_version, nil)

    test_pid = self()
    gate = make_ref()

    completion =
      Task.async(fn ->
        Connectors.complete_authorization("gmail", "authorization-code", consumed,
          now: ~U[2026-08-11 01:00:00.000000Z],
          provider_opts:
            completion_provider_opts(address,
              test_pid: test_pid,
              exchange_gate: gate
            )
        )
      end)

    assert_receive {:oauth_code_exchanged, completion_pid, ^gate}, 5_000

    assert {:ok, _rotated} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "rotated-client", "client_secret" => "rotated-secret"},
               expected_lock_version: gmail_setting.lock_version
             )

    send(completion_pid, {:release_oauth_exchange, gate})

    assert {:error, %CoreError{class: :permanent, reason: :provider_configuration_changed}} =
             Task.await(completion, 5_000)

    assert Repo.aggregate(OAuthAuthorization, :count) == 0
    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(SendMethod, :count) == 0
    assert Repo.aggregate(ConnectorEvent, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "receive grant creates shared authorization and linked receive state", %{
    account: account,
    address: address
  } do
    assert {:ok, %ReceiveMethod{} = receive} = complete(:receive, account, address)
    assert receive.oauth_authorization_id
    assert receive.account_id == account.id
    assert receive.provider_account_id == "google-subject-1"
    assert receive.email_address == address
    assert receive.granted_scopes == [GmailScopes.read()]

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    assert authorization.account_id == account.id
    assert authorization.provider_subject_id == "google-subject-1"
    assert authorization.email_address == address
    assert authorization.granted_scopes == [GmailScopes.read()]
    assert authorization.status == "connected"
    refute Repo.get_by(Credential, external_account_id: receive.id)

    assert {:ok, "access-secret"} =
             Crypto.decrypt(
               authorization.access_token_ciphertext,
               "credential:#{authorization.id}:access"
             )

    assert {:ok, "refresh-secret"} =
             Crypto.decrypt(
               authorization.refresh_token_ciphertext,
               "credential:#{authorization.id}:refresh"
             )

    assert %SyncCursor{scope: "mailbox", phase: "initial"} =
             Repo.get_by!(SyncCursor, external_account_id: receive.id)

    connected_event = Repo.get_by!(ConnectorEvent, event_type: "connected")
    assert Map.get(connected_event, :oauth_authorization_id) == authorization.id
    assert is_nil(connected_event.external_account_id)

    assert Repo.get_by!(Oban.Job,
             worker: inspect(SyncAccount),
             args: %{"external_account_id" => receive.id}
           )
  end

  test "send-first creates only shared authorization and Gmail send method", %{
    account: account,
    address: address
  } do
    assert {:ok, %SendMethod{kind: "gmail"} = send_method} =
             complete(:send, account, address)

    assert send_method.oauth_authorization_id
    assert send_method.account_id == account.id
    assert send_method.email_address == address
    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(SyncCursor, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0

    authorization = Repo.get!(OAuthAuthorization, send_method.oauth_authorization_id)
    assert authorization.granted_scopes == [GmailScopes.send()]
    refute Repo.get_by(Credential, external_account_id: send_method.id)

    connected_event = Repo.get_by!(ConnectorEvent, event_type: "connected")
    assert Map.get(connected_event, :oauth_authorization_id) == authorization.id
    assert is_nil(connected_event.external_account_id)
  end

  test "receive-to-send upgrade preserves refresh and adds only send state", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    before = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    assert {:ok, send_method} =
             complete(:send, account, address,
               access_token: "upgraded-access-secret",
               refresh_token: nil,
               scopes: [GmailScopes.send(), "email", GmailScopes.read(), "unapproved-scope"]
             )

    authorization = Repo.get!(OAuthAuthorization, send_method.oauth_authorization_id)
    assert authorization.id == before.id
    assert authorization.refresh_token_ciphertext == before.refresh_token_ciphertext
    assert authorization.granted_scopes == Enum.sort([GmailScopes.read(), GmailScopes.send()])
    assert Repo.get!(ReceiveMethod, receive.id).granted_scopes == [GmailScopes.read()]
    assert Repo.aggregate(ReceiveMethod, :count) == 1
    assert Repo.aggregate(SendMethod, :count) == 1
    assert Repo.aggregate(SyncCursor, :count) == 1
    assert sync_job_count(receive.id) == 1

    assert {:ok, "upgraded-access-secret"} =
             Crypto.decrypt(
               authorization.access_token_ciphertext,
               "credential:#{authorization.id}:access"
             )

    scope_event = Repo.get_by!(ConnectorEvent, event_type: "scope_upgraded")
    assert Map.get(scope_event, :oauth_authorization_id) == authorization.id
    assert is_nil(scope_event.external_account_id)
  end

  test "OAuth upgrade and token refresh telemetry is useful and secret-free", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    attach_telemetry([
      [:manifold, :connectors, :oauth, :complete, :stop],
      [:manifold, :connectors, :oauth, :refresh, :stop]
    ])

    assert {:ok, send_method} =
             complete(:send, account, address,
               code: "raw-authorization-code",
               access_token: "raw-upgraded-access-token",
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    assert_receive {:telemetry, [:manifold, :connectors, :oauth, :complete, :stop],
                    %{duration_ms: duration_ms, attempt_count: 1} = measurements,
                    %{
                      account_id: account_id,
                      authorization_id: authorization_id,
                      method_id: method_id,
                      provider: "gmail",
                      method_kind: "gmail",
                      outcome: :scope_upgraded
                    } = metadata}

    assert is_integer(duration_ms) and duration_ms >= 0
    assert account_id == account.id
    assert authorization_id == authorization.id
    assert method_id == send_method.id

    assert_secret_free_telemetry(measurements, metadata, [
      "raw-authorization-code",
      "raw-upgraded-access-token",
      "refresh-secret"
    ])

    refreshed = %Token{
      access_token: "raw-refreshed-access-token",
      refresh_token: "raw-refreshed-refresh-token",
      expires_at: ~U[2026-08-11 04:00:00.000000Z],
      scopes: [GmailScopes.read(), GmailScopes.send()]
    }

    assert {:ok, "raw-refreshed-access-token"} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: GmailScopes.send(),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [refresh_result: {:ok, refreshed}]
             )

    assert_receive {:telemetry, [:manifold, :connectors, :oauth, :refresh, :stop],
                    %{duration_ms: refresh_duration, attempt_count: 1} = refresh_measurements,
                    %{
                      account_id: refresh_account_id,
                      authorization_id: refresh_authorization_id,
                      provider: "gmail",
                      method_kind: "gmail",
                      outcome: :refreshed
                    } = refresh_metadata}

    assert is_integer(refresh_duration) and refresh_duration >= 0
    assert refresh_account_id == account.id
    assert refresh_authorization_id == authorization.id

    assert_secret_free_telemetry(refresh_measurements, refresh_metadata, [
      "raw-refreshed-access-token",
      "raw-refreshed-refresh-token",
      "refresh-secret"
    ])

    reconnect_error = %ProviderError{
      class: :reconnect,
      code: :invalid_grant,
      message: "raw-refresh-token-secret must not escape"
    }

    assert {:error, %ProviderError{code: :invalid_grant}} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: GmailScopes.send(),
               now: ~U[2026-08-11 05:00:00.000000Z],
               provider_opts: [refresh_result: {:error, reconnect_error}]
             )

    assert_receive {:telemetry, [:manifold, :connectors, :oauth, :refresh, :stop],
                    %{duration_ms: reconnect_duration, attempt_count: 1} = reconnect_measurements,
                    %{
                      authorization_id: reconnect_authorization_id,
                      outcome: :reconnect_required,
                      error_code: :invalid_grant
                    } = reconnect_metadata}

    assert is_integer(reconnect_duration) and reconnect_duration >= 0
    assert reconnect_authorization_id == authorization.id

    assert_secret_free_telemetry(reconnect_measurements, reconnect_metadata, [
      "raw-refresh-token-secret",
      "raw-refreshed-access-token",
      "raw-refreshed-refresh-token"
    ])
  end

  test "OAuth completion emits one sanitized stop event when a database failure is rescued", %{
    account: account,
    address: address
  } do
    attach_telemetry([[:manifold, :connectors, :oauth, :complete, :stop]])

    database_error = %DBConnection.ConnectionError{
      message: "database-password-secret during OAuth completion"
    }

    assert {:error, %CoreError{class: :temporary, reason: :database_unavailable}} =
             complete(:send, account, address, provider_opts: [raise: database_error])

    assert_receive {:telemetry, [:manifold, :connectors, :oauth, :complete, :stop], measurements,
                    %{
                      account_id: account_id,
                      outcome: :error,
                      error_code: :database_unavailable
                    } = metadata}

    assert account_id == account.id
    assert_secret_free_telemetry(measurements, metadata, ["database-password-secret"])
    refute_receive {:telemetry, [:manifold, :connectors, :oauth, :complete, :stop], _, _}
  end

  test "OAuth completion emits one sanitized stop event before reraising an unexpected exception",
       %{
         account: account,
         address: address
       } do
    attach_telemetry([[:manifold, :connectors, :oauth, :complete, :stop]])
    exception = RuntimeError.exception("authorization_code unexpected-complete-secret")

    assert_raise RuntimeError, "authorization_code unexpected-complete-secret", fn ->
      complete(:send, account, address, provider_opts: [raise: exception])
    end

    assert_receive {:telemetry, [:manifold, :connectors, :oauth, :complete, :stop], measurements,
                    %{
                      account_id: account_id,
                      outcome: :error,
                      error_code: :unexpected_exception
                    } = metadata}

    assert account_id == account.id
    assert_secret_free_telemetry(measurements, metadata, ["unexpected-complete-secret"])
    refute_receive {:telemetry, [:manifold, :connectors, :oauth, :complete, :stop], _, _}
  end

  test "send-to-receive upgrade preserves send scope and initializes receive only then", %{
    account: account,
    address: address
  } do
    assert {:ok, send_method} = complete(:send, account, address)
    before = Repo.get!(OAuthAuthorization, send_method.oauth_authorization_id)
    assert Repo.aggregate(SyncCursor, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0

    assert {:ok, receive} =
             complete(:receive, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    assert authorization.refresh_token_ciphertext == before.refresh_token_ciphertext
    assert authorization.granted_scopes == Enum.sort([GmailScopes.read(), GmailScopes.send()])
    assert Repo.get!(SendMethod, send_method.id).status == "connected"
    assert Repo.aggregate(SyncCursor, :count) == 1
    assert sync_job_count(receive.id) == 1
  end

  test "missing stored scope rejects an upgrade without partial changes", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    before = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    assert {:error, %{class: :permanent, reason: :insufficient_provider_scope}} =
             complete(:send, account, address,
               access_token: "rejected-access-secret",
               refresh_token: "rejected-refresh-secret",
               scopes: [GmailScopes.send()]
             )

    after_failure = Repo.get!(OAuthAuthorization, before.id)
    assert after_failure.access_token_ciphertext == before.access_token_ciphertext
    assert after_failure.refresh_token_ciphertext == before.refresh_token_ciphertext
    assert after_failure.granted_scopes == before.granted_scopes
    assert Repo.aggregate(SendMethod, :count) == 0
    assert Repo.aggregate(ConnectorEvent, :count) == 1
  end

  test "canonical addresses match exactly without Gmail dot or plus normalization", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} =
             complete(:receive, account, address,
               identity: %Identity{
                 id: "google-subject-1",
                 email_address: String.upcase(address)
               }
             )

    assert Repo.get!(OAuthAuthorization, receive.oauth_authorization_id).email_address == address

    [local, domain] = String.split(address, "@", parts: 2)

    assert {:error, %{class: :permanent, reason: :provider_address_mismatch}} =
             complete(:send, account, address,
               scopes: [GmailScopes.read(), GmailScopes.send()],
               identity: %Identity{
                 id: "google-subject-1",
                 email_address: local <> "+alias@" <> domain
               }
             )

    assert Repo.aggregate(SendMethod, :count) == 0
  end

  test "permanent subject binding survives final disconnect and permits only the same subject", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    authorization_id = receive.oauth_authorization_id

    assert {:ok, disconnected} = Connectors.disconnect(receive.id)
    assert disconnected.status == "disconnected"

    disconnected_authorization = Repo.get!(OAuthAuthorization, authorization_id)
    assert disconnected_authorization.status == "disconnected"
    assert disconnected_authorization.provider_subject_id == "google-subject-1"
    assert disconnected_authorization.email_address == address
    assert is_nil(disconnected_authorization.access_token_ciphertext)
    assert is_nil(disconnected_authorization.refresh_token_ciphertext)
    assert is_nil(disconnected_authorization.token_expires_at)

    assert {:error, %{class: :permanent, reason: :provider_identity_mismatch}} =
             complete(:receive, account, address,
               identity: %Identity{id: "different-subject", email_address: address}
             )

    assert {:ok, reconnected} = complete(:receive, account, address)
    assert reconnected.id == receive.id
    assert Repo.get!(OAuthAuthorization, authorization_id).status == "connected"
  end

  test "a provider subject cannot move accounts while distinct subjects can bind distinctly", %{
    account: account,
    address: address
  } do
    assert {:ok, _receive} = complete(:receive, account, address)
    {:ok, other_account} = Accounts.create_account(account.domain, %{local_part: "other"})
    other_account = Repo.preload(other_account, :domain)
    other_address = Accounts.account_address(other_account)

    assert {:error, %{class: :permanent, reason: :provider_identity_already_bound}} =
             complete(:receive, other_account, other_address,
               identity: %Identity{id: "google-subject-1", email_address: other_address}
             )

    assert {:ok, other_receive} =
             complete(:receive, other_account, other_address,
               identity: %Identity{id: "google-subject-2", email_address: other_address}
             )

    assert Repo.get!(OAuthAuthorization, other_receive.oauth_authorization_id).provider_subject_id ==
             "google-subject-2"

    assert Repo.aggregate(OAuthAuthorization, :count) == 2
  end

  test "refresh replacement is atomic and a new authorization requires refresh", %{
    account: account,
    address: address
  } do
    assert {:error, %{class: :permanent, reason: :missing_refresh_token}} =
             complete(:send, account, address, refresh_token: nil)

    assert Repo.aggregate(OAuthAuthorization, :count) == 0
    assert Repo.aggregate(SendMethod, :count) == 0

    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, _updated} =
             complete(:receive, account, address,
               access_token: "replacement-access-secret",
               refresh_token: "replacement-refresh-secret"
             )

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    assert {:ok, "replacement-refresh-secret"} =
             Crypto.decrypt(
               authorization.refresh_token_ciphertext,
               "credential:#{authorization.id}:refresh"
             )
  end

  test "completion disables methods only in the requested direction", %{
    account: account,
    address: address
  } do
    other_receive = insert_other_receive!(account.id, address)
    other_send = insert_other_send!(account.id, address)

    assert {:ok, gmail_send} = complete(:send, account, address)
    refute Repo.get!(SendMethod, other_send.id).enabled
    assert Repo.get!(ReceiveMethod, other_receive.id).enabled

    assert {:ok, gmail_receive} =
             complete(:receive, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    refute Repo.get!(ReceiveMethod, other_receive.id).enabled
    assert Repo.get!(SendMethod, gmail_send.id).enabled
    assert Repo.get!(ReceiveMethod, gmail_receive.id).enabled
  end

  test "disconnecting one direction keeps the other live and final disconnect clears only tokens",
       %{
         account: account,
         address: address
       } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, send_method} =
             complete(:send, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    assert {:ok, disconnected_receive} = Connectors.disconnect(receive.id)
    assert disconnected_receive.status == "disconnected"
    assert Repo.get!(SendMethod, send_method.id).status == "connected"

    still_live = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    assert still_live.status == "connected"
    assert still_live.access_token_ciphertext
    assert still_live.refresh_token_ciphertext

    assert {:ok, disconnected_send} =
             Connectors.disconnect_send_method(account.id, send_method.id)

    assert disconnected_send.status == "disconnected"

    final = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    assert final.status == "disconnected"
    assert final.provider_subject_id == "google-subject-1"
    assert final.email_address == address
    assert is_nil(final.access_token_ciphertext)
    assert is_nil(final.refresh_token_ciphertext)
    assert is_nil(final.token_expires_at)

    assert Enum.all?(Repo.all(ConnectorEvent), fn event ->
             Map.get(event, :oauth_authorization_id) == final.id and
               is_nil(event.external_account_id)
           end)
  end

  test "mark_reconnect_required disables every dependent Gmail method and retains secrets", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, send_method} =
             complete(:send, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    before = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    error = %ProviderError{
      class: :reconnect,
      code: :invalid_grant,
      message: "raw-refresh-secret must never be stored"
    }

    assert function_exported?(
             Manifold.Connectors.OAuthAuthorizations,
             :mark_reconnect_required,
             2
           )

    assert {:ok, authorization} =
             Manifold.Connectors.OAuthAuthorizations.mark_reconnect_required(before.id, error)

    assert authorization.status == "reconnect_required"
    assert authorization.last_error_class == "reconnect"
    assert authorization.last_error_code == "invalid_grant"
    assert authorization.last_error_message == "Gmail authorization must be reconnected"
    assert authorization.access_token_ciphertext == before.access_token_ciphertext
    assert authorization.refresh_token_ciphertext == before.refresh_token_ciphertext

    persisted_receive = Repo.get!(ReceiveMethod, receive.id)
    assert persisted_receive.status == "reconnect_required"
    refute persisted_receive.enabled
    refute persisted_receive.sync_enabled

    persisted_send = Repo.get!(SendMethod, send_method.id)
    assert persisted_send.status == "reconnect_required"
    refute persisted_send.enabled

    event = Repo.get_by!(ConnectorEvent, event_type: "reconnect_required")
    assert Map.get(event, :oauth_authorization_id) == before.id
    refute inspect(event) =~ "raw-refresh-secret"
    refute Enum.any?(Repo.all(Oban.Job), &(inspect(&1) =~ "raw-refresh-secret"))
  end

  test "reconnect propagation makes pre-mark receive changesets stale", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    stale_receive = Repo.get!(ReceiveMethod, receive.id)

    stale_checkpoint =
      ReceiveMethod.changeset(stale_receive, %{
        status: "connected",
        last_synced_at: ~U[2026-08-11 03:00:00.000000Z],
        last_error_class: nil,
        last_error_code: nil,
        last_error_message: nil
      })

    assert {:ok, _authorization} =
             Connectors.mark_oauth_reconnect_required(
               receive.oauth_authorization_id,
               reconnect_error(),
               expected_access_token: "access-secret"
             )

    assert_raise Ecto.StaleEntryError, fn -> Repo.update(stale_checkpoint) end

    persisted = Repo.get!(ReceiveMethod, receive.id)
    assert persisted.status == "reconnect_required"
    assert persisted.last_error_code == "invalid_grant"
  end

  test "stale reconnect after final disconnect leaves the authorization disconnected", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, send_method} =
             complete(:send, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    assert {:ok, _receive} = Connectors.disconnect(receive.id)
    assert {:ok, _send} = Connectors.disconnect_send_method(account.id, send_method.id)
    events_before = Repo.aggregate(ConnectorEvent, :count)

    assert {:ok, authorization} =
             Connectors.mark_oauth_reconnect_required(
               receive.oauth_authorization_id,
               %ProviderError{
                 class: :reconnect,
                 code: :invalid_grant,
                 message: "raw-old-token-secret must never escape"
               },
               expected_access_token: "access-secret"
             )

    assert authorization.status == "disconnected"
    assert is_nil(authorization.access_token_ciphertext)
    assert is_nil(authorization.refresh_token_ciphertext)
    assert Repo.get!(ReceiveMethod, receive.id).status == "disconnected"
    assert Repo.get!(SendMethod, send_method.id).status == "disconnected"
    assert Repo.aggregate(ConnectorEvent, :count) == events_before
    refute inspect(authorization) =~ "raw-old-token-secret"
  end

  test "stale old-token reconnect after reauthorization leaves the new generation healthy", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, send_method} =
             complete(:send, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    assert {:ok, _reauthorized} =
             complete(:receive, account, address,
               access_token: "new-generation-access",
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    events_before = Repo.aggregate(ConnectorEvent, :count)

    assert {:ok, authorization} =
             Connectors.mark_oauth_reconnect_required(
               receive.oauth_authorization_id,
               %ProviderError{
                 class: :reconnect,
                 code: :invalid_grant,
                 message: "raw-stale-generation-secret must never escape"
               },
               expected_access_token: "access-secret"
             )

    assert authorization.status == "connected"
    assert Repo.get!(ReceiveMethod, receive.id).status == "connected"
    assert Repo.get!(ReceiveMethod, receive.id).enabled
    assert Repo.get!(SendMethod, send_method.id).status == "connected"
    assert Repo.get!(SendMethod, send_method.id).enabled
    assert Repo.aggregate(ConnectorEvent, :count) == events_before

    assert {:ok, "new-generation-access"} =
             Crypto.decrypt(
               authorization.access_token_ciphertext,
               "credential:#{authorization.id}:access"
             )

    refute inspect(authorization) =~ "raw-stale-generation-secret"
  end

  test "mark_reconnect_required rolls back authorization and methods atomically", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, send_method} =
             complete(:send, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    events_before = Repo.aggregate(ConnectorEvent, :count)

    error = %ProviderError{
      class: :reconnect,
      code: :invalid_grant,
      message: "provider authentication failed"
    }

    assert {:error, %{reason: :after_methods_before_event}} =
             Manifold.Connectors.OAuthAuthorizations.mark_reconnect_required(
               authorization.id,
               error,
               fail_at: :after_methods_before_event
             )

    assert Repo.get!(OAuthAuthorization, authorization.id).status == "connected"
    assert Repo.get!(ReceiveMethod, receive.id).status == "connected"
    assert Repo.get!(ReceiveMethod, receive.id).enabled
    assert Repo.get!(ReceiveMethod, receive.id).sync_enabled
    assert Repo.get!(SendMethod, send_method.id).status == "connected"
    assert Repo.get!(SendMethod, send_method.id).enabled
    assert Repo.aggregate(ConnectorEvent, :count) == events_before
  end

  test "a reconnect-required receive method cannot replace the working alternate", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, _authorization} =
             Manifold.Connectors.OAuthAuthorizations.mark_reconnect_required(
               receive.oauth_authorization_id,
               reconnect_error()
             )

    alternate = insert_other_receive!(account.id, address)

    assert {:error, %{class: :permanent, reason: :reauthorization_required}} =
             Connectors.enable_receive_method(receive.id)

    refute Repo.get!(ReceiveMethod, receive.id).enabled
    refute Repo.get!(ReceiveMethod, receive.id).sync_enabled
    assert Repo.get!(ReceiveMethod, alternate.id).enabled
    assert Repo.get!(ReceiveMethod, alternate.id).sync_enabled
  end

  test "a reconnect-required send method cannot replace the working alternate", %{
    account: account,
    address: address
  } do
    assert {:ok, send_method} = complete(:send, account, address)

    assert {:ok, _authorization} =
             Manifold.Connectors.OAuthAuthorizations.mark_reconnect_required(
               send_method.oauth_authorization_id,
               reconnect_error()
             )

    alternate = insert_other_send!(account.id, address)

    assert {:error, %{class: :permanent, reason: :reauthorization_required}} =
             Connectors.enable_send_method(account.id, send_method.id)

    refute Repo.get!(SendMethod, send_method.id).enabled
    assert Repo.get!(SendMethod, alternate.id).enabled
  end

  test "receive reauthorization repairs both Gmail directions", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, send_method} =
             complete(:send, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    assert {:ok, _authorization} =
             Manifold.Connectors.OAuthAuthorizations.mark_reconnect_required(
               receive.oauth_authorization_id,
               reconnect_error()
             )

    alternate_receive = insert_other_receive!(account.id, address)
    alternate_send = insert_other_send!(account.id, address)

    assert {:ok, repaired_receive} =
             complete(:receive, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    assert repaired_receive.id == receive.id
    assert_gmail_methods_repaired(receive.id, send_method.id)
    refute Repo.get!(ReceiveMethod, alternate_receive.id).enabled
    refute Repo.get!(SendMethod, alternate_send.id).enabled
  end

  test "send reauthorization repairs both Gmail directions", %{
    account: account,
    address: address
  } do
    assert {:ok, send_method} = complete(:send, account, address)

    assert {:ok, receive} =
             complete(:receive, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    assert {:ok, _authorization} =
             Manifold.Connectors.OAuthAuthorizations.mark_reconnect_required(
               receive.oauth_authorization_id,
               reconnect_error()
             )

    alternate_receive = insert_other_receive!(account.id, address)
    alternate_send = insert_other_send!(account.id, address)

    assert {:ok, repaired_send} =
             complete(:send, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    assert repaired_send.id == send_method.id
    assert_gmail_methods_repaired(receive.id, send_method.id)
    refute Repo.get!(ReceiveMethod, alternate_receive.id).enabled
    refute Repo.get!(SendMethod, alternate_send.id).enabled
  end

  test "deleting a Gmail receive method keeps a live send authorization", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, send_method} =
             complete(:send, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    before = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    assert sync_job_count(receive.id) == 1

    assert {:ok, deleted} = Connectors.delete_receive_method(receive.id)
    assert deleted.id == receive.id
    refute Repo.get(ReceiveMethod, receive.id)
    assert sync_job_count(receive.id) == 0

    authorization = Repo.get!(OAuthAuthorization, before.id)
    assert authorization.status == "connected"
    assert authorization.access_token_ciphertext == before.access_token_ciphertext
    assert authorization.refresh_token_ciphertext == before.refresh_token_ciphertext
    assert Repo.get!(SendMethod, send_method.id).status == "connected"
  end

  test "deleting the final Gmail receive method disconnects the shared authorization", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    before = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    assert {:ok, deleted} = Connectors.delete_receive_method(receive.id)
    assert deleted.id == receive.id
    refute Repo.get(ReceiveMethod, receive.id)
    assert sync_job_count(receive.id) == 0

    authorization = Repo.get!(OAuthAuthorization, before.id)
    assert authorization.status == "disconnected"
    assert authorization.provider_subject_id == before.provider_subject_id
    assert authorization.email_address == before.email_address
    assert is_nil(authorization.access_token_ciphertext)
    assert is_nil(authorization.refresh_token_ciphertext)
    assert is_nil(authorization.token_expires_at)

    event = Repo.get_by!(ConnectorEvent, event_type: "disconnected")
    assert event.oauth_authorization_id == before.id
    assert is_nil(event.external_account_id)
  end

  test "Gmail disconnect locks the authorization before its receive method", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    queries =
      repo_queries_during(fn -> assert {:ok, _method} = Connectors.disconnect(receive.id) end)

    assert authorization_lock_index(queries) < receive_method_lock_index(queries)
  end

  test "Gmail direct delete locks the authorization before its receive method", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    queries =
      repo_queries_during(fn ->
        assert {:ok, _method} = Connectors.delete_receive_method(receive.id)
      end)

    assert authorization_lock_index(queries) < receive_method_lock_index(queries)
  end

  test "connector events require exactly one legacy or Gmail authorization anchor" do
    now = ~U[2026-08-11 01:00:00.000000Z]

    legacy =
      ConnectorEvent.changeset(%ConnectorEvent{}, %{
        external_account_id: Ecto.UUID.generate(),
        event_type: "connected",
        metadata: %{},
        occurred_at: now
      })

    assert legacy.valid?

    authorization =
      ConnectorEvent.changeset(%ConnectorEvent{}, %{
        oauth_authorization_id: Ecto.UUID.generate(),
        event_type: "connected",
        metadata: %{},
        occurred_at: now
      })

    assert authorization.valid?

    refute ConnectorEvent.changeset(%ConnectorEvent{}, %{
             external_account_id: Ecto.UUID.generate(),
             oauth_authorization_id: Ecto.UUID.generate(),
             event_type: "connected",
             metadata: %{},
             occurred_at: now
           }).valid?

    refute ConnectorEvent.changeset(%ConnectorEvent{}, %{
             event_type: "connected",
             metadata: %{},
             occurred_at: now
           }).valid?

    constraints =
      authorization.constraints
      |> Enum.map(&to_string(&1.constraint))

    assert "connector_events_anchor_valid" in constraints
  end

  test "database rejects connector events with both or neither anchor", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    now = ~U[2026-08-11 01:00:00.000000Z]

    both = %{
      id: Ecto.UUID.generate(),
      external_account_id: receive.id,
      oauth_authorization_id: receive.oauth_authorization_id,
      event_type: "connected",
      metadata: %{},
      occurred_at: now,
      inserted_at: now
    }

    neither = %{
      both
      | id: Ecto.UUID.generate(),
        external_account_id: nil,
        oauth_authorization_id: nil
    }

    for invalid <- [both, neither] do
      assert_raise Postgrex.Error, fn ->
        Repo.transaction(
          fn -> Repo.insert_all(ConnectorEvent, [invalid]) end,
          mode: :savepoint
        )
      end
    end
  end

  test "account deletion cascades both Gmail methods and the shared authorization", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, _send_method} =
             complete(:send, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    # connector_accounts.mailbox_id intentionally retains its pre-existing RESTRICT FK,
    # so explicit receive-method cleanup remains the account deletion boundary.
    assert {:ok, _disconnected} = Connectors.disconnect(receive.id)
    assert {:ok, _deleted} = Connectors.delete_receive_method(receive.id)
    Repo.delete!(account)

    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(SendMethod, :count) == 0
    assert Repo.aggregate(OAuthAuthorization, :count) == 0
  end

  test "rejected grants do not leak or persist callback secrets", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    before = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    assert {:error, error} =
             complete(:send, account, address,
               code: "raw-authorization-code",
               access_token: "raw-access-token",
               refresh_token: "raw-refresh-token",
               scopes: [GmailScopes.send()]
             )

    refute inspect(error) =~ "raw-authorization-code"
    refute inspect(error) =~ "raw-access-token"
    refute inspect(error) =~ "raw-refresh-token"

    assert Repo.get!(OAuthAuthorization, before.id).access_token_ciphertext ==
             before.access_token_ciphertext

    assert Repo.aggregate(SendMethod, :count) == 0

    for value <- Repo.all(ConnectorEvent) ++ Repo.all(Oban.Job) do
      serialized = inspect(value)
      refute serialized =~ "raw-authorization-code"
      refute serialized =~ "raw-access-token"
      refute serialized =~ "raw-refresh-token"
      refute serialized =~ "verifier-secret"
    end
  end

  test "adapter scope fallback comes from the consumed callback transaction", %{
    account: account,
    address: address
  } do
    assert {:ok, %SendMethod{}} =
             complete(:send, account, address,
               provider_opts: [test_pid: self(), required_scopes: ["attacker-supplied"]]
             )

    assert_receive {:exchange_required_scopes, [scope]}
    assert scope == GmailScopes.send()
  end

  test "current access token is checked out without provider refresh", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    {:ok, refresh_count} = Agent.start_link(fn -> 0 end)

    assert {:ok, "access-secret"} =
             Connectors.checkout_oauth_access_token(receive.oauth_authorization_id,
               required_scope: GmailScopes.read(),
               now: ~U[2026-08-11 01:00:00.000000Z],
               provider_opts: [refresh_count: refresh_count]
             )

    assert Agent.get(refresh_count, & &1) == 0
  end

  test "access-token continuation keeps the default API compatible", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, {:continued, "access-secret"}} =
             Connectors.checkout_oauth_access_token(receive.oauth_authorization_id,
               required_scope: GmailScopes.read(),
               now: ~U[2026-08-11 01:00:00.000000Z],
               access_token_continuation: fn token -> {:ok, {:continued, token}} end
             )

    assert {:ok, "access-secret"} =
             Connectors.checkout_oauth_access_token(receive.oauth_authorization_id,
               required_scope: GmailScopes.read(),
               now: ~U[2026-08-11 01:00:00.000000Z]
             )
  end

  test "continuation errors commit a successful token refresh", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    refreshed = %Token{
      access_token: "continued-refresh-token",
      refresh_token: nil,
      expires_at: ~U[2026-08-11 04:00:00.000000Z],
      scopes: [GmailScopes.read()]
    }

    assert {:error, %CoreError{reason: :continuation_rejected}} =
             Connectors.checkout_oauth_access_token(receive.oauth_authorization_id,
               required_scope: GmailScopes.read(),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [refresh_result: {:ok, refreshed}],
               access_token_continuation: fn "continued-refresh-token" ->
                 {:error,
                  CoreError.new(:permanent, :continuation_rejected, "continuation rejected")}
               end
             )

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    assert authorization.token_expires_at == refreshed.expires_at

    assert {:ok, "continued-refresh-token"} =
             Crypto.decrypt(
               authorization.access_token_ciphertext,
               "credential:#{authorization.id}:access"
             )
  end

  test "missing trusted scope fails before provider refresh", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    {:ok, refresh_count} = Agent.start_link(fn -> 0 end)

    assert {:error, %{class: :permanent, reason: :insufficient_provider_scope}} =
             Connectors.checkout_oauth_access_token(receive.oauth_authorization_id,
               required_scope: GmailScopes.send(),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [refresh_count: refresh_count]
             )

    assert Agent.get(refresh_count, & &1) == 0
  end

  test "corrupted current access ciphertext returns a generic credential error", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    {:ok, refresh_count} = Agent.start_link(fn -> 0 end)

    authorization
    |> OAuthAuthorization.changeset(%{access_token_ciphertext: "corrupted-access-secret"})
    |> Repo.update!()

    assert {:error,
            %{
              class: :permanent,
              reason: :invalid_credential_envelope,
              message: "encrypted connector credential envelope is invalid"
            } = error} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: GmailScopes.read(),
               now: ~U[2026-08-11 01:00:00.000000Z],
               provider_opts: [refresh_count: refresh_count]
             )

    refute inspect(error) =~ "corrupted-access-secret"
    assert Agent.get(refresh_count, & &1) == 0
  end

  test "corrupted refresh ciphertext returns a generic credential error before provider I/O", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    {:ok, refresh_count} = Agent.start_link(fn -> 0 end)

    authorization
    |> OAuthAuthorization.changeset(%{refresh_token_ciphertext: "corrupted-refresh-secret"})
    |> Repo.update!()

    assert {:error,
            %{
              class: :permanent,
              reason: :invalid_credential_envelope,
              message: "encrypted connector credential envelope is invalid"
            } = error} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: GmailScopes.read(),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [refresh_count: refresh_count]
             )

    refute inspect(error) =~ "corrupted-refresh-secret"
    assert Agent.get(refresh_count, & &1) == 0
  end

  test "expired token refresh rotates access and refresh tokens atomically", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    refreshed = %Token{
      access_token: "new-access",
      refresh_token: "rotated-refresh",
      expires_at: ~U[2026-08-11 04:00:00.000000Z],
      scopes: [GmailScopes.read()]
    }

    queries =
      repo_queries_during(fn ->
        assert {:ok, "new-access"} =
                 Connectors.checkout_oauth_access_token(authorization.id,
                   required_scope: GmailScopes.read(),
                   now: ~U[2026-08-11 03:00:00.000000Z],
                   provider_opts: [test_pid: self(), refresh_result: {:ok, refreshed}]
                 )
      end)

    assert_receive {:refresh_token, "refresh-secret"}
    assert_receive {:refresh_config, refresh_config}
    assert refresh_config[:client_id] == "db-client"
    assert refresh_config[:client_secret] == "db-secret"
    assert is_integer(authorization_lock_index(queries))
    persisted = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted.token_expires_at == refreshed.expires_at
    assert persisted.granted_scopes == [GmailScopes.read()]

    assert {:ok, "new-access"} =
             Crypto.decrypt(
               persisted.access_token_ciphertext,
               "credential:#{authorization.id}:access"
             )

    assert {:ok, "rotated-refresh"} =
             Crypto.decrypt(
               persisted.refresh_token_ciphertext,
               "credential:#{authorization.id}:refresh"
             )
  end

  test "the next refresh resolves a setting rotated before the operation", %{
    account: account,
    address: address,
    gmail_setting: gmail_setting
  } do
    assert {:ok, _rotated} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "rotated-client", "client_secret" => "rotated-secret"},
               expected_lock_version: gmail_setting.lock_version
             )

    assert {:ok, receive} = complete(:receive, account, address)
    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    refreshed = %Token{
      access_token: "rotated-setting-access",
      refresh_token: nil,
      expires_at: ~U[2026-08-11 04:00:00.000000Z],
      scopes: [GmailScopes.read()]
    }

    assert {:ok, "rotated-setting-access"} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: GmailScopes.read(),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [test_pid: self(), refresh_result: {:ok, refreshed}]
             )

    assert_receive {:refresh_config, config}
    assert config[:client_id] == "rotated-client"
    assert config[:client_secret] == "rotated-secret"
  end

  test "missing and corrupt settings stop refresh before provider I/O", %{
    account: account,
    address: address,
    gmail_setting: gmail_setting
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    Repo.delete!(gmail_setting)

    assert {:error, %CoreError{reason: :provider_not_configured}} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: GmailScopes.read(),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [
                 test_pid: self(),
                 refresh_result: {:ok, must_not_refresh_token()}
               ]
             )

    refute_receive {:refresh_config, _config}

    sentinel = "refresh-corrupt-setting-secret-#{System.unique_integer([:positive])}"

    assert {:ok, _setting} =
             Connectors.put_oauth_provider_setting("gmail", %{
               "client_id" => "corrupt-client",
               "client_secret" => sentinel
             })

    setting = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    {:ok, corrupt_ciphertext} = Crypto.encrypt(sentinel, "wrong-provider-setting-context")

    setting
    |> Ecto.Changeset.change(client_secret_ciphertext: corrupt_ciphertext)
    |> Repo.update!()

    assert {:error, %CoreError{reason: :provider_configuration_error} = error} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: GmailScopes.read(),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [
                 test_pid: self(),
                 refresh_result: {:ok, must_not_refresh_token()}
               ]
             )

    refute inspect(error) =~ sentinel
    refute inspect(error) =~ "ciphertext"
    refute_receive {:refresh_config, _config}
  end

  test "authorized receive setup uses stored credentials and fails closed when missing", %{
    account: account,
    address: address,
    gmail_setting: gmail_setting
  } do
    Application.put_env(:manifold_connectors, :gmail_authorizations_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:manifold_connectors, :gmail_authorizations_test_pid)
    end)

    token = %Token{
      access_token: "authorized-setup-access",
      refresh_token: "authorized-setup-refresh",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
      scopes: [GmailScopes.read(), GmailScopes.send()]
    }

    assert {:ok, _send_method} = complete(:send, account, address, token: token)

    assert {:ok, %ReceiveMethod{}} =
             Connectors.add_authorized_oauth_method(account.id, "gmail", :receive)

    assert_receive {:initial_cursors_config, config}
    assert config[:client_id] == "db-client"
    assert config[:client_secret] == "db-secret"

    Repo.delete!(gmail_setting)

    assert {:error, %CoreError{reason: :provider_not_configured}} =
             Connectors.add_authorized_oauth_method(account.id, "gmail", :receive)

    refute_receive {:initial_cursors_config, _config}
  end

  test "authorized send setup requires the stored Gmail setting", %{
    account: account,
    address: address,
    gmail_setting: gmail_setting
  } do
    token = %Token{
      access_token: "authorized-send-access",
      refresh_token: "authorized-send-refresh",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
      scopes: [GmailScopes.read(), GmailScopes.send()]
    }

    assert {:ok, _receive_method} = complete(:receive, account, address, token: token)

    assert {:ok, %SendMethod{}} =
             Connectors.add_authorized_oauth_method(account.id, "gmail", :send)

    Repo.delete!(gmail_setting)

    assert {:error, %CoreError{reason: :provider_not_configured}} =
             Connectors.add_authorized_oauth_method(account.id, "gmail", :send)
  end

  test "refresh omission preserves the stored refresh token", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    refreshed = %Token{
      access_token: "new-access",
      refresh_token: nil,
      expires_at: ~U[2026-08-11 04:00:00.000000Z],
      scopes: [GmailScopes.read()]
    }

    assert {:ok, "new-access"} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: GmailScopes.read(),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [refresh_result: {:ok, refreshed}]
             )

    persisted = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted.refresh_token_ciphertext == authorization.refresh_token_ciphertext
  end

  test "refresh rejects returned scopes that omit the stored authorization union", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, _send_method} =
             complete(:send, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    refreshed = %Token{
      access_token: "rejected-access",
      refresh_token: "rejected-refresh",
      expires_at: ~U[2026-08-11 04:00:00.000000Z],
      scopes: [GmailScopes.read()]
    }

    assert {:error, %{class: :permanent, reason: :insufficient_provider_scope}} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: GmailScopes.read(),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [refresh_result: {:ok, refreshed}]
             )

    persisted = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted.access_token_ciphertext == authorization.access_token_ciphertext
    assert persisted.refresh_token_ciphertext == authorization.refresh_token_ciphertext
  end

  test "two concurrent callers share one serialized refresh", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    {:ok, refresh_count} = Agent.start_link(fn -> 0 end)
    gate = make_ref()
    test_pid = self()

    refreshed = %Token{
      access_token: "new-access",
      refresh_token: nil,
      expires_at: ~U[2026-08-11 04:00:00.000000Z],
      scopes: [GmailScopes.read()]
    }

    opts = [
      required_scope: GmailScopes.read(),
      now: ~U[2026-08-11 03:00:00.000000Z],
      provider_opts: [
        refresh_count: refresh_count,
        refresh_gate: gate,
        refresh_result: {:ok, refreshed},
        test_pid: test_pid
      ]
    ]

    callers =
      for _ <- 1..2 do
        Task.async(fn ->
          send(test_pid, {:checkout_ready, self()})

          receive do
            :checkout ->
              Connectors.checkout_oauth_access_token(receive.oauth_authorization_id, opts)
          end
        end)
      end

    caller_pids =
      for _ <- 1..2 do
        assert_receive {:checkout_ready, caller_pid}
        caller_pid
      end

    Enum.each(caller_pids, &send(&1, :checkout))
    assert_receive {:refresh_token, "refresh-secret"}
    refute_receive {:refresh_token, _}, 100
    send(hd(callers).pid, {:release_refresh, gate})
    send(List.last(callers).pid, {:release_refresh, gate})

    assert Enum.map(callers, &Task.await(&1, 5_000)) == [
             {:ok, "new-access"},
             {:ok, "new-access"}
           ]

    assert Agent.get(refresh_count, & &1) == 1
  end

  test "refresh invalid_grant atomically requires reconnect for both Gmail methods", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, send_method} =
             complete(:send, account, address,
               refresh_token: nil,
               scopes: [GmailScopes.read(), GmailScopes.send()]
             )

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    error = %ProviderError{
      class: :reconnect,
      code: :invalid_grant,
      message: "raw-refresh-secret must never escape"
    }

    assert {:error,
            %ProviderError{
              class: :reconnect,
              code: :invalid_grant,
              message: "Gmail authorization must be reconnected"
            } = returned_error} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: GmailScopes.send(),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [refresh_result: {:error, error}]
             )

    refute inspect(returned_error) =~ "raw-refresh-secret"

    persisted = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted.status == "reconnect_required"
    assert persisted.last_error_code == "invalid_grant"

    receive = Repo.get!(ReceiveMethod, receive.id)
    assert receive.status == "reconnect_required"
    refute receive.enabled
    refute receive.sync_enabled

    send_method = Repo.get!(SendMethod, send_method.id)
    assert send_method.status == "reconnect_required"
    refute send_method.enabled

    assert Repo.get_by!(ConnectorEvent,
             oauth_authorization_id: authorization.id,
             event_type: "reconnect_required"
           )
  end

  defp complete(purpose, account, address, opts \\ []) do
    purpose_scope = if purpose == :receive, do: GmailScopes.read(), else: GmailScopes.send()
    required_scopes = Keyword.get(opts, :required_scopes, [purpose_scope])

    consumed = %Consumed{
      provider: "gmail",
      mailbox_id: account.id,
      purpose: purpose,
      required_scopes: required_scopes,
      redirect_uri: "https://mail.example.test/connectors/gmail/callback",
      pkce_verifier: "verifier-secret"
    }

    token =
      Keyword.get(
        opts,
        :token,
        %Token{
          access_token: Keyword.get(opts, :access_token, "access-secret"),
          refresh_token: Keyword.get(opts, :refresh_token, "refresh-secret"),
          expires_at: ~U[2026-08-11 02:00:00.000000Z],
          scopes: Keyword.get(opts, :scopes, ["openid", "email", purpose_scope])
        }
      )

    identity =
      Keyword.get(opts, :identity, %Identity{
        id: "google-subject-1",
        email_address: address
      })

    provider_opts =
      Keyword.merge(
        [token: {:ok, token}, identity: {:ok, identity}],
        Keyword.get(opts, :provider_opts, [])
      )

    Manifold.Connectors.OAuthAuthorizations.complete(
      "gmail",
      Keyword.get(opts, :code, "authorization-code-secret"),
      consumed,
      FakeGmail,
      [],
      now: ~U[2026-08-11 01:00:00.000000Z],
      provider_opts: provider_opts
    )
  end

  defp start_and_consume_gmail!(account_id) do
    redirect_uri = "https://mail.example.test/connectors/gmail/callback"
    assert {:ok, authorization} = OAuth.start("gmail", account_id, redirect_uri)
    assert {:ok, consumed} = OAuth.consume("gmail", authorization.state, redirect_uri)
    consumed
  end

  defp completion_provider_opts(address, extra) do
    token = %Token{
      access_token: "access-secret",
      refresh_token: "refresh-secret",
      expires_at: ~U[2026-08-11 02:00:00.000000Z],
      scopes: ["openid", "email", GmailScopes.read()]
    }

    Keyword.merge(
      [
        token: {:ok, token},
        identity: {:ok, %Identity{id: "google-subject-1", email_address: address}}
      ],
      extra
    )
  end

  defp must_not_refresh_token do
    %Token{
      access_token: "must-not-refresh",
      refresh_token: nil,
      expires_at: ~U[2026-08-11 04:00:00.000000Z],
      scopes: [GmailScopes.read()]
    }
  end

  defp insert_other_receive!(account_id, address) do
    %ReceiveMethod{}
    |> ReceiveMethod.changeset(%{
      account_id: account_id,
      kind: "imap",
      provider_account_id: "imap:#{address}",
      email_address: address,
      status: "connected",
      enabled: true,
      sync_enabled: true,
      granted_scopes: []
    })
    |> Repo.insert!()
  end

  defp insert_other_send!(account_id, address) do
    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: account_id,
      kind: "smtp",
      email_address: address,
      status: "connected",
      enabled: true
    })
    |> Repo.insert!()
  end

  defp sync_job_count(receive_method_id) do
    Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == ^inspect(SyncAccount) and
            fragment("?->>'external_account_id' = ?", job.args, ^receive_method_id)
      ),
      :count
    )
  end

  defp reconnect_error do
    %ProviderError{
      class: :reconnect,
      code: :invalid_grant,
      message: "provider authentication failed"
    }
  end

  defp assert_gmail_methods_repaired(receive_method_id, send_method_id) do
    receive = Repo.get!(ReceiveMethod, receive_method_id)
    assert receive.status == "connected"
    assert receive.enabled
    assert receive.sync_enabled
    assert is_nil(receive.last_error_class)
    assert is_nil(receive.last_error_code)
    assert is_nil(receive.last_error_message)

    send_method = Repo.get!(SendMethod, send_method_id)
    assert send_method.status == "connected"
    assert send_method.enabled
    assert is_nil(send_method.last_error_class)
    assert is_nil(send_method.last_error_code)
    assert is_nil(send_method.last_error_message)

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    assert authorization.status == "connected"
    assert is_nil(authorization.last_error_class)
    assert is_nil(authorization.last_error_code)
    assert is_nil(authorization.last_error_message)
  end

  defp repo_queries_during(fun) do
    handler_id = "gmail-lifecycle-query-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          send(pid, {:gmail_lifecycle_query, handler_id, metadata.query})
        end,
        test_pid
      )

    try do
      fun.()
      received_repo_queries(handler_id)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp attach_telemetry(events) do
    handler_id = "gmail-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp assert_secret_free_telemetry(measurements, metadata, secret_values) do
    assert Map.keys(measurements) |> Enum.sort() == [:attempt_count, :duration_ms]

    forbidden_fragments =
      ~w(token password authorization_code raw_message) ++
        Enum.map(secret_values, &String.downcase/1)

    telemetry_terms(measurements)
    |> Enum.concat(telemetry_terms(metadata))
    |> Enum.each(fn term ->
      downcased = term |> to_string() |> String.downcase()

      refute Enum.any?(forbidden_fragments, &String.contains?(downcased, &1)),
             "unsafe telemetry term: #{inspect(term)}"
    end)
  end

  defp telemetry_terms(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> [key | telemetry_terms(value)] end)
  end

  defp telemetry_terms(list) when is_list(list), do: Enum.flat_map(list, &telemetry_terms/1)

  defp telemetry_terms(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> telemetry_terms()

  defp telemetry_terms(value), do: [value]

  defp received_repo_queries(handler_id, queries \\ []) do
    receive do
      {:gmail_lifecycle_query, ^handler_id, query} ->
        received_repo_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp authorization_lock_index(queries) do
    Enum.find_index(queries, fn query ->
      String.contains?(query, ~s(FROM "connector_oauth_authorizations")) and
        String.contains?(query, "FOR UPDATE")
    end)
  end

  defp receive_method_lock_index(queries) do
    Enum.find_index(queries, fn query ->
      String.contains?(query, ~s(FROM "connector_accounts")) and
        String.contains?(query, "FOR UPDATE")
    end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

defmodule Manifold.Connectors.GmailAuthorizationGenerationConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Manifold.Accounts
  alias Manifold.Accounts.Schema.{Account, Domain}
  alias Manifold.Connectors
  alias Manifold.Connectors.GmailAuthorizationsTest.FakeGmail
  alias Manifold.Connectors.GmailScopes
  alias Manifold.Connectors.OAuth
  alias Manifold.Connectors.Provider.{Identity, Token}

  alias Manifold.Connectors.Schema.{
    OAuthAuthorization,
    OAuthProviderSetting,
    OAuthTransaction,
    ReceiveMethod,
    SendMethod,
    SyncCursor
  }

  alias Manifold.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_adapters = Application.get_env(:manifold_connectors, :adapters)
    old_providers = Application.get_env(:manifold_connectors, :providers)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :adapters, gmail: FakeGmail)

    Application.put_env(:manifold_connectors, :providers,
      gmail: [authorization_url: "https://accounts.google.test/authorize"]
    )

    Repo.delete_all(from(setting in OAuthProviderSetting, where: setting.provider == "gmail"))

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "gmail-fence-#{suffix}.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "person"})
    account = Repo.preload(account, :domain)

    assert {:ok, setting_view} =
             Connectors.put_oauth_provider_setting("gmail", %{
               "client_id" => "db-client",
               "client_secret" => "db-secret"
             })

    setting = Repo.get_by!(OAuthProviderSetting, provider: "gmail")

    on_exit(fn ->
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        cleanup_fixture(account.id, domain.id)
      after
        restore_env(:encryption_key, old_key)
        restore_env(:adapters, old_adapters)
        restore_env(:providers, old_providers)
        Sandbox.checkin(Repo)
      end
    end)

    {:ok, account: account, setting: setting, setting_view: setting_view}
  end

  test "completion owns the provider lock before account locks and rotation reconnects its result",
       %{
         account: account,
         setting: setting,
         setting_view: setting_view
       } do
    redirect_uri = "https://mail.example.test/connectors/gmail/callback"
    assert {:ok, authorization} = OAuth.start("gmail", account.id, redirect_uri)
    assert {:ok, consumed} = OAuth.consume("gmail", authorization.state, redirect_uri)

    test_pid = self()
    gate = make_ref()

    account_holder =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            assert {:ok, _account} = Accounts.active_account_for_update(Repo, account.id)
            send(test_pid, {:account_locked, self(), gate})

            receive do
              {:release_account, ^gate} -> :ok
            end
          end)
        end)
      end)

    assert_receive {:account_locked, account_holder_pid, ^gate}, 5_000

    completion =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          token = %Token{
            access_token: "access-secret",
            refresh_token: "refresh-secret",
            expires_at: ~U[2026-08-11 02:00:00.000000Z],
            scopes: ["openid", "email", GmailScopes.read()]
          }

          identity = %Identity{
            id: "google-concurrent-subject",
            email_address: Accounts.account_address(account)
          }

          Connectors.complete_authorization("gmail", "authorization-code", consumed,
            now: ~U[2026-08-11 01:00:00.000000Z],
            provider_opts: [token: {:ok, token}, identity: {:ok, identity}]
          )
        end)
      end)

    assert_provider_lock_state(1, 0)

    rotation =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          send(test_pid, {:rotation_attempting, self(), gate})

          Connectors.put_oauth_provider_setting(
            "gmail",
            %{"client_id" => "rotated-client", "client_secret" => "rotated-secret"},
            expected_lock_version: setting_view.lock_version
          )
        end)
      end)

    assert_receive {:rotation_attempting, _rotation_pid, ^gate}, 5_000
    assert_provider_lock_state(1, 1)

    send(account_holder_pid, {:release_account, gate})
    assert {:ok, :ok} = Task.await(account_holder, 5_000)
    assert {:ok, %ReceiveMethod{} = completed_method} = Task.await(completion, 5_000)
    assert {:ok, rotated_view} = Task.await(rotation, 5_000)
    assert rotated_view.lock_version == setting.lock_version + 1

    authorization = Repo.get!(OAuthAuthorization, completed_method.oauth_authorization_id)
    receive = Repo.get!(ReceiveMethod, completed_method.id)

    assert authorization.status == "reconnect_required"
    assert authorization.last_error_code == "oauth_provider_configuration_changed"
    assert receive.status == "reconnect_required"
    refute receive.enabled
    refute receive.sync_enabled
  end

  defp assert_provider_lock_state(granted, waiting, attempts \\ 500)

  defp assert_provider_lock_state(_granted, _waiting, 0) do
    flunk("provider advisory lock did not reach the expected state")
  end

  defp assert_provider_lock_state(granted, waiting, attempts) do
    case provider_lock_state() do
      {^granted, ^waiting} -> :ok
      _state -> assert_provider_lock_state(granted, waiting, attempts - 1)
    end
  end

  defp provider_lock_state do
    %{rows: [[granted, waiting]]} =
      Repo.query!(
        """
        WITH key AS (
          SELECT hashtextextended($1::text, 0) AS value
        )
        SELECT
          COUNT(*) FILTER (WHERE locks.granted),
          COUNT(*) FILTER (WHERE NOT locks.granted)
        FROM pg_locks AS locks
        CROSS JOIN key
        WHERE locks.locktype = 'advisory'
          AND locks.classid::bigint = ((key.value >> 32) & 4294967295)
          AND locks.objid::bigint = (key.value & 4294967295)
        """,
        ["oauth_provider_setting:gmail"]
      )

    {granted, waiting}
  end

  defp cleanup_fixture(account_id, domain_id) do
    receive_ids =
      ReceiveMethod
      |> where([method], method.account_id == ^account_id)
      |> select([method], method.id)
      |> Repo.all()

    Repo.delete_all(
      from(job in Oban.Job,
        where: fragment("?->>'external_account_id' = ANY(?)", job.args, ^receive_ids)
      )
    )

    Repo.delete_all(from(cursor in SyncCursor, where: cursor.external_account_id in ^receive_ids))
    Repo.delete_all(from(method in ReceiveMethod, where: method.account_id == ^account_id))
    Repo.delete_all(from(method in SendMethod, where: method.account_id == ^account_id))
    Repo.delete_all(from(auth in OAuthAuthorization, where: auth.account_id == ^account_id))

    Repo.delete_all(
      from(transaction in OAuthTransaction, where: transaction.mailbox_id == ^account_id)
    )

    Repo.delete_all(from(account in Account, where: account.id == ^account_id))
    Repo.delete_all(from(domain in Domain, where: domain.id == ^domain_id))
    Repo.delete_all(from(setting in OAuthProviderSetting, where: setting.provider == "gmail"))
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

defmodule Manifold.Connectors.SubmissionMethodTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, GmailScopes, MicrosoftScopes, SubmissionMethod}
  alias Manifold.Connectors.Provider.{Error, Identity, Page, RawMessage, Token}

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    OAuthAuthorization,
    OAuthProviderSetting,
    ReceiveMethod,
    SendCredential,
    SendMethod,
    SmtpSettings
  }

  alias Manifold.Core.Error, as: CoreError
  alias Manifold.Repo

  defmodule FakeGmail do
    @behaviour Manifold.Connectors.Provider

    @impl true
    def exchange_code(_code, _verifier, _redirect_uri, _config, _opts), do: raise("not used")

    @impl true
    def identity(_access_token, _config, _opts),
      do: {:ok, %Identity{id: "unused", email_address: "unused@example.test"}}

    @impl true
    def initial_cursors(_access_token, _config, _opts), do: {:ok, []}

    @impl true
    def refresh_token(_refresh_token, config, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:send_refresh_config, config})
      end

      Keyword.fetch!(opts, :refresh_result)
    end

    @impl true
    def sync_page(_access_token, cursor, _config, _opts), do: {:ok, %Page{cursor: cursor}}

    @impl true
    def fetch_raw(_access_token, _message_id, _config, _opts),
      do: {:ok, %RawMessage{bytes: ""}}
  end

  setup do
    previous_key = Application.get_env(:manifold_connectors, :encryption_key)
    previous_adapters = Application.get_env(:manifold_connectors, :adapters)
    previous_providers = Application.get_env(:manifold_connectors, :providers)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :adapters,
      gmail: FakeGmail,
      microsoft: FakeGmail
    )

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        authorization_url: "https://accounts.google.test/authorize",
        base_url: "https://gmail.test",
        req_options: [
          plug: {Req.Test, __MODULE__},
          headers: [{"cookie", "gmail-config-cookie-secret"}]
        ]
      ],
      microsoft: [
        authorization_url: "https://login.microsoft.test/authorize",
        token_url: "https://login.microsoft.test/token",
        base_url: "https://graph.microsoft.test/v1.0",
        tenant: "organizations",
        req_options: [plug: {Req.Test, __MODULE__}]
      ]
    )

    assert {:ok, _setting} =
             Connectors.put_oauth_provider_setting("gmail", %{
               "client_id" => "db-client-id-must-not-escape",
               "client_secret" => "db-client-secret-must-not-escape"
             })

    assert {:ok, _setting} =
             Connectors.put_oauth_provider_setting("microsoft", %{
               "client_id" => "microsoft-db-client-id-must-not-escape",
               "client_secret" => "microsoft-db-client-secret-must-not-escape"
             })

    on_exit(fn ->
      restore_env(:encryption_key, previous_key)
      restore_env(:adapters, previous_adapters)
      restore_env(:providers, previous_providers)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "submission#{suffix}.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "sender"})
    {:ok, other_account} = Accounts.create_account(domain, %{local_part: "other"})

    %{
      account: Repo.preload(account, :domain),
      other_account: Repo.preload(other_account, :domain)
    }
  end

  test "enabled_send_method requires an account-scoped enabled method", %{
    account: account,
    other_account: other_account
  } do
    assert {:error, %CoreError{class: :permanent, reason: :send_method_required}} =
             Connectors.enabled_send_method(account.id)

    other_gmail = insert_gmail_method!(other_account, "other-subject")

    assert {:error, %CoreError{reason: :send_method_required}} =
             Connectors.enabled_send_method(account.id)

    gmail = insert_gmail_method!(account, "sender-subject")

    assert {:ok,
            %SubmissionMethod{
              id: gmail_id,
              account_id: account_id,
              kind: "gmail",
              email_address: email_address,
              credential: nil,
              config: nil
            }} = Connectors.enabled_send_method(account.id)

    assert gmail_id == gmail.id
    assert account_id == account.id
    assert email_address == Accounts.account_address(account)

    assert {:ok, %SubmissionMethod{id: other_id}} =
             Connectors.enabled_send_method(other_account.id)

    assert other_id == other_gmail.id
  end

  test "enabled_send_method locks the selected row", %{account: account} do
    gmail = insert_gmail_method!(account, "sender-subject")

    queries =
      repo_queries_during(fn ->
        assert {:ok, %SubmissionMethod{id: method_id}} =
                 Connectors.enabled_send_method(account.id)

        assert method_id == gmail.id
      end)

    assert Enum.any?(queries, fn query ->
             String.contains?(query, ~s(FROM "connector_send_methods")) and
               String.contains?(query, "FOR UPDATE")
           end)
  end

  test "Gmail checkout is isolated by method and returns only gmail.send material", %{
    account: account,
    other_account: other_account
  } do
    gmail = insert_gmail_method!(account, "sender-subject", access_token: "sender-token")

    other_gmail =
      insert_gmail_method!(other_account, "other-subject", access_token: "other-token")

    assert {:ok,
            %SubmissionMethod{
              id: gmail_id,
              account_id: account_id,
              kind: "gmail",
              email_address: sender,
              credential: {:oauth, "sender-token"},
              config: gmail_config
            } = checked_out} =
             Connectors.checkout_send_method(gmail.id, Accounts.account_address(account))

    assert gmail_id == gmail.id
    assert account_id == account.id
    assert sender == Accounts.account_address(account)
    assert gmail_config[:base_url] == "https://gmail.test"
    assert gmail_config[:req_options][:plug] == {Req.Test, __MODULE__}
    refute Keyword.has_key?(gmail_config, :client_id)
    refute Keyword.has_key?(gmail_config, :client_secret)
    refute inspect(checked_out) =~ "sender-token"
    refute inspect(checked_out) =~ "client-secret-must-not-escape"
    refute inspect(checked_out) =~ "db-client-secret-must-not-escape"
    refute inspect(checked_out) =~ "gmail-config-cookie-secret"
    assert inspect(checked_out) =~ "config: :redacted"

    assert {:ok, %SubmissionMethod{credential: {:oauth, "other-token"}}} =
             Connectors.checkout_send_method(
               other_gmail.id,
               Accounts.account_address(other_account)
             )
  end

  test "Gmail send checkout stops at a missing stored setting", %{
    account: account
  } do
    gmail =
      insert_gmail_method!(account, "sender-subject", expires_at: ~U[2026-08-11 01:00:00.000000Z])

    setting = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    Repo.delete!(setting)

    assert {:error, %CoreError{reason: :provider_not_configured} = missing_error} =
             Connectors.checkout_send_method(gmail.id, Accounts.account_address(account),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [test_pid: self(), refresh_result: {:ok, send_refresh_token()}]
             )

    refute inspect(missing_error) =~ "db-client-secret-must-not-escape"
    refute_receive {:send_refresh_config, _config}
  end

  test "Gmail send checkout stops at a corrupt stored setting", %{account: account} do
    sentinel = "send-checkout-corrupt-secret-#{System.unique_integer([:positive])}"

    gmail =
      insert_gmail_method!(account, "sender-subject", expires_at: ~U[2026-08-11 01:00:00.000000Z])

    setting = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    {:ok, corrupt_ciphertext} = Crypto.encrypt(sentinel, "wrong-provider-setting-context")

    setting
    |> Ecto.Changeset.change(client_secret_ciphertext: corrupt_ciphertext)
    |> Repo.update!()

    assert {:error, %CoreError{reason: :provider_configuration_error} = corrupt_error} =
             Connectors.checkout_send_method(gmail.id, Accounts.account_address(account),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [test_pid: self(), refresh_result: {:ok, send_refresh_token()}]
             )

    refute inspect(corrupt_error) =~ sentinel
    refute inspect(corrupt_error) =~ "ciphertext"
    refute_receive {:send_refresh_config, _config}
  end

  test "Gmail send checkout refresh uses the stored client credentials", %{account: account} do
    gmail =
      insert_gmail_method!(account, "sender-subject", expires_at: ~U[2026-08-11 01:00:00.000000Z])

    assert {:ok, %SubmissionMethod{} = checked_out} =
             Connectors.checkout_send_method(gmail.id, Accounts.account_address(account),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [test_pid: self(), refresh_result: {:ok, send_refresh_token()}]
             )

    assert_receive {:send_refresh_config, config}
    assert config[:client_id] == "db-client-id-must-not-escape"
    assert config[:client_secret] == "db-client-secret-must-not-escape"
    refute inspect(checked_out) =~ "db-client-secret-must-not-escape"
  end

  test "Gmail checkout rejects a missing gmail.send grant without exposing a token", %{
    account: account
  } do
    gmail =
      insert_gmail_method!(account, "sender-subject",
        scopes: [GmailScopes.read()],
        access_token: "read-only-token"
      )

    assert {:error, %CoreError{class: :permanent, reason: :insufficient_provider_scope} = error} =
             Connectors.checkout_send_method(gmail.id, Accounts.account_address(account))

    refute inspect(error) =~ "read-only-token"
  end

  test "Microsoft send checkout requires Mail.Send and exact canonical sender", %{
    account: account
  } do
    microsoft =
      insert_microsoft_method!(account, "microsoft-subject",
        scopes: [MicrosoftScopes.read()],
        access_token: "microsoft-read-only-token"
      )

    assert {:error, %CoreError{class: :permanent, reason: :insufficient_provider_scope}} =
             Connectors.checkout_send_method(
               microsoft.id,
               Accounts.account_address(account)
             )

    OAuthAuthorization
    |> Repo.get!(microsoft.oauth_authorization_id)
    |> OAuthAuthorization.changeset(%{granted_scopes: [MicrosoftScopes.send()]})
    |> Repo.update!()

    assert {:error, %CoreError{class: :permanent, reason: :sender_address_mismatch}} =
             Connectors.checkout_send_method(microsoft.id, "different@example.test")

    assert {:ok, %SubmissionMethod{credential: {:oauth, "microsoft-read-only-token"}}} =
             Connectors.checkout_send_method(
               microsoft.id,
               String.upcase(Accounts.account_address(account))
             )
  end

  test "Microsoft send checkout returns only a redacted short-lived token and base URL", %{
    account: account
  } do
    sentinel = "task5-access-token-sentinel-#{System.unique_integer([:positive])}"

    microsoft =
      insert_microsoft_method!(account, "microsoft-subject",
        access_token: "expired-access-token-secret",
        expires_at: ~U[2026-08-12 01:00:00.000000Z]
      )

    handler_id = "microsoft-send-checkout-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :connectors, :oauth, :refresh, :stop],
        fn event, measurements, metadata, pid ->
          send(pid, {:microsoft_checkout_telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    try do
      refreshed = %Token{
        access_token: sentinel,
        refresh_token: nil,
        expires_at: ~U[2026-08-12 04:00:00.000000Z],
        scopes: [MicrosoftScopes.send()]
      }

      assert {:ok,
              %SubmissionMethod{
                credential: {:oauth, ^sentinel},
                config: config
              } = method} =
               Connectors.checkout_send_method(
                 microsoft.id,
                 Accounts.account_address(account),
                 now: ~U[2026-08-12 03:00:00.000000Z],
                 provider_opts: [test_pid: self(), refresh_result: {:ok, refreshed}]
               )

      assert_receive {:send_refresh_config, refresh_config}
      assert refresh_config[:client_id] == "microsoft-db-client-id-must-not-escape"
      assert refresh_config[:client_secret] == "microsoft-db-client-secret-must-not-escape"

      assert Enum.sort(Keyword.keys(config)) == [:base_url, :req_options]
      assert config[:base_url] == "https://graph.microsoft.test/v1.0"
      assert config[:req_options] == [plug: {Req.Test, __MODULE__}]

      assert_receive {:microsoft_checkout_telemetry, _event, measurements, metadata}

      refute inspect(method) =~ sentinel
      refute inspect(method.config) =~ sentinel
      refute inspect(Repo.get!(SendMethod, microsoft.id)) =~ sentinel
      refute inspect(Repo.get!(OAuthAuthorization, microsoft.oauth_authorization_id)) =~ sentinel
      refute inspect(Repo.all(ConnectorEvent)) =~ sentinel
      refute inspect(Repo.all(Oban.Job)) =~ sentinel
      refute inspect({measurements, metadata}) =~ sentinel

      refute inspect(method.config) =~ "microsoft-db-client-id-must-not-escape"
      refute inspect(method.config) =~ "microsoft-db-client-secret-must-not-escape"
      refute inspect(method.config) =~ "organizations"
    after
      :telemetry.detach(handler_id)
    end
  end

  test "generic OAuth send revocation marks Microsoft authorization and both methods", %{
    account: account
  } do
    microsoft =
      insert_microsoft_method!(account, "microsoft-shared-subject",
        scopes: [MicrosoftScopes.read(), MicrosoftScopes.send()]
      )

    receive =
      insert_microsoft_receive!(
        account,
        microsoft.oauth_authorization_id,
        "microsoft-shared-subject"
      )

    assert {:ok, :marked, %OAuthAuthorization{status: "reconnect_required"}} =
             Connectors.mark_oauth_send_reconnect_required(
               microsoft.id,
               "microsoft-access-token",
               :invalid_grant
             )

    persisted_send = Repo.get!(SendMethod, microsoft.id)
    assert persisted_send.status == "reconnect_required"
    refute persisted_send.enabled

    persisted_receive = Repo.get!(ReceiveMethod, receive.id)
    assert persisted_receive.status == "reconnect_required"
    refute persisted_receive.enabled
    refute persisted_receive.sync_enabled
  end

  test "method changes after queue snapshot fail revalidation", %{account: account} do
    sentinel = "snapshot-token-sentinel-#{System.unique_integer([:positive])}"

    microsoft =
      insert_microsoft_method!(account, "microsoft-subject", access_token: sentinel)

    assert {:error, %CoreError{reason: :send_method_required} = error} =
             Connectors.checkout_send_method(
               microsoft.id,
               Accounts.account_address(account),
               after_oauth_checkout: fn ->
                 microsoft
                 |> SendMethod.changeset(%{email_address: String.upcase(microsoft.email_address)})
                 |> Repo.update!()
               end
             )

    refute inspect(error) =~ sentinel
  end

  test "disconnecting and re-adding a method after queue snapshot fails revalidation", %{
    account: account
  } do
    sentinel = "aba-token-sentinel-#{System.unique_integer([:positive])}"

    microsoft =
      insert_microsoft_method!(account, "microsoft-subject",
        access_token: sentinel,
        scopes: [MicrosoftScopes.read(), MicrosoftScopes.send()]
      )

    insert_microsoft_receive!(account, microsoft.oauth_authorization_id, "microsoft-subject")

    assert {:error, %CoreError{reason: :send_method_required} = error} =
             Connectors.checkout_send_method(
               microsoft.id,
               Accounts.account_address(account),
               after_oauth_checkout: fn ->
                 assert {:ok, disconnected} =
                          Connectors.disconnect_send_method(account.id, microsoft.id)

                 assert disconnected.status == "disconnected"
                 assert disconnected.lock_version > microsoft.lock_version

                 assert {:ok, readded} =
                          Connectors.add_authorized_oauth_method(
                            account.id,
                            "microsoft",
                            :send
                          )

                 assert readded.id == microsoft.id
                 assert readded.status == microsoft.status
                 assert readded.enabled == microsoft.enabled
                 assert readded.lock_version > disconnected.lock_version
               end
             )

    refute inspect(error) =~ sentinel
  end

  test "a revoked authorization prevents unsent work from checking out a token", %{
    account: account
  } do
    sentinel = "revoked-token-sentinel-#{System.unique_integer([:positive])}"
    microsoft = insert_microsoft_method!(account, "microsoft-subject", access_token: sentinel)

    OAuthAuthorization
    |> Repo.get!(microsoft.oauth_authorization_id)
    |> OAuthAuthorization.changeset(%{
      status: "reconnect_required",
      last_error_class: "reconnect",
      last_error_code: "invalid_grant",
      last_error_message: "provider-response-secret-must-not-escape"
    })
    |> Repo.update!()

    assert Repo.get!(SendMethod, microsoft.id).enabled

    assert {:error, %CoreError{class: :permanent, reason: :reauthorization_required} = error} =
             Connectors.checkout_send_method(
               microsoft.id,
               Accounts.account_address(account)
             )

    refute inspect(error) =~ sentinel
    refute inspect(error) =~ "provider-response-secret-must-not-escape"
  end

  test "checkout rejects sender mismatch and methods disabled after selection", %{
    account: account
  } do
    gmail = insert_gmail_method!(account, "sender-subject")

    assert {:ok, %SubmissionMethod{id: selected_id}} =
             Connectors.enabled_send_method(account.id)

    assert selected_id == gmail.id

    assert {:error, %CoreError{class: :permanent, reason: :sender_address_mismatch}} =
             Connectors.checkout_send_method(gmail.id, "different@example.test")

    gmail
    |> SendMethod.changeset(%{enabled: false})
    |> Repo.update!()

    assert {:error, %CoreError{class: :permanent, reason: :send_method_required}} =
             Connectors.checkout_send_method(selected_id, Accounts.account_address(account))
  end

  test "checkout rejects disconnected and reconnect-required send methods", %{account: account} do
    disconnected =
      insert_gmail_method!(account, "sender-subject", enabled: false, status: "disconnected")

    assert {:error, %CoreError{class: :permanent, reason: :account_disconnected}} =
             Connectors.checkout_send_method(
               disconnected.id,
               Accounts.account_address(account)
             )

    reconnect =
      disconnected
      |> SendMethod.changeset(%{status: "reconnect_required", enabled: false})
      |> Repo.update!()

    assert {:error, %CoreError{class: :permanent, reason: :reauthorization_required}} =
             Connectors.checkout_send_method(reconnect.id, Accounts.account_address(account))
  end

  test "enabled resolver rejects stale enabled methods that are not connected", %{
    account: account
  } do
    smtp = insert_smtp_method!(account, "smtp-password-secret")

    Enum.reduce(["failed", "disconnected", "reconnect_required"], smtp, fn status, method ->
      method =
        method
        |> SendMethod.changeset(%{status: status, enabled: true})
        |> Repo.update!()

      assert {:error, %CoreError{reason: :send_method_required}} =
               Connectors.enabled_send_method(account.id)

      method
    end)
  end

  test "SMTP checkout decrypts only the purpose-bound password and redacts it", %{
    account: account
  } do
    smtp = insert_smtp_method!(account, "smtp-password-secret")

    assert {:ok,
            %SubmissionMethod{
              id: smtp_id,
              kind: "smtp",
              credential: {:password, "smtp-password-secret"},
              config: %{host: "smtp.test", port: 587, tls_mode: "starttls", username: username}
            } = checked_out} =
             Connectors.checkout_send_method(smtp.id, Accounts.account_address(account))

    assert smtp_id == smtp.id
    assert username == Accounts.account_address(account)
    refute inspect(checked_out) =~ "smtp-password-secret"

    future_config_secret =
      %{checked_out | config: Map.put(checked_out.config, :future_secret, "smtp-config-secret")}

    refute inspect(future_config_secret) =~ "smtp-config-secret"
    assert inspect(future_config_secret) =~ "config: :redacted"

    credential = Repo.get_by!(SendCredential, send_method_id: smtp.id)
    {:ok, wrong_ciphertext} = Crypto.encrypt("wrong-aad-secret", "credential:other:smtp_password")

    credential
    |> SendCredential.changeset(%{password_ciphertext: wrong_ciphertext})
    |> Repo.update!()

    assert {:error, %CoreError{reason: :credential_authentication_failed} = error} =
             Connectors.checkout_send_method(smtp.id, Accounts.account_address(account))

    refute inspect(error) =~ "wrong-aad-secret"
  end

  test "Gmail invalid_grant lifecycle persists through send-method checkout", %{account: account} do
    gmail =
      insert_gmail_method!(account, "sender-subject",
        scopes: [GmailScopes.read(), GmailScopes.send()],
        expires_at: ~U[2026-08-11 01:00:00.000000Z]
      )

    receive = insert_gmail_receive!(account, gmail.oauth_authorization_id, "sender-subject")

    provider_error = %Error{
      class: :reconnect,
      code: :invalid_grant,
      message: "refresh-secret-must-not-escape"
    }

    assert {:error,
            %Error{
              class: :reconnect,
              code: :invalid_grant,
              message: "Gmail authorization must be reconnected"
            } = returned_error} =
             Connectors.checkout_send_method(gmail.id, Accounts.account_address(account),
               now: ~U[2026-08-11 03:00:00.000000Z],
               provider_opts: [refresh_result: {:error, provider_error}]
             )

    refute inspect(returned_error) =~ "refresh-secret-must-not-escape"

    authorization = Repo.get!(OAuthAuthorization, gmail.oauth_authorization_id)
    assert authorization.status == "reconnect_required"
    assert authorization.last_error_code == "invalid_grant"

    persisted_send = Repo.get!(SendMethod, gmail.id)
    assert persisted_send.status == "reconnect_required"
    refute persisted_send.enabled

    persisted_receive = Repo.get!(ReceiveMethod, receive.id)
    assert persisted_receive.status == "reconnect_required"
    refute persisted_receive.enabled
    refute persisted_receive.sync_enabled

    assert Repo.get_by!(ConnectorEvent,
             oauth_authorization_id: authorization.id,
             event_type: "reconnect_required"
           )
  end

  test "Gmail checkout locks authorization before final method validation", %{account: account} do
    gmail = insert_gmail_method!(account, "sender-subject")

    queries =
      repo_queries_during(fn ->
        assert {:ok, %SubmissionMethod{}} =
                 Connectors.checkout_send_method(gmail.id, Accounts.account_address(account))
      end)

    authorization_lock =
      Enum.find_index(queries, fn query ->
        String.contains?(query, ~s(FROM "connector_oauth_authorizations")) and
          String.contains?(query, "FOR UPDATE")
      end)

    method_lock =
      Enum.find_index(queries, fn query ->
        String.contains?(query, ~s(FROM "connector_send_methods")) and
          String.contains?(query, "FOR UPDATE")
      end)

    assert is_integer(authorization_lock)
    assert is_integer(method_lock)
    assert authorization_lock < method_lock
  end

  test "Gmail checkout returns no token when the method disconnects after token checkout", %{
    account: account
  } do
    gmail = insert_gmail_method!(account, "sender-subject", access_token: "raced-token-secret")

    assert {:error, %CoreError{reason: :account_disconnected} = error} =
             Connectors.checkout_send_method(gmail.id, Accounts.account_address(account),
               after_oauth_checkout: fn ->
                 assert {:ok, _disconnected} =
                          Connectors.disconnect_send_method(account.id, gmail.id)
               end
             )

    refute inspect(error) =~ "raced-token-secret"
    refute Repo.get!(SendMethod, gmail.id).enabled
  end

  test "Gmail token replacement cannot interleave with method validation", %{account: account} do
    gmail = insert_gmail_method!(account, "sender-subject", access_token: "current-token")
    test_pid = self()

    checkout =
      Task.async(fn ->
        Connectors.checkout_send_method(gmail.id, Accounts.account_address(account),
          after_oauth_checkout: fn ->
            send(test_pid, {:gmail_continuation_ready, self()})

            receive do
              :finish_method_validation -> :ok
            end
          end
        )
      end)

    assert_receive {:gmail_continuation_ready, checkout_pid}

    replacement =
      Task.async(fn ->
        Repo.transaction(fn ->
          authorization =
            OAuthAuthorization
            |> where([authorization], authorization.id == ^gmail.oauth_authorization_id)
            |> lock("FOR UPDATE")
            |> Repo.one!()

          send(test_pid, :replacement_obtained_authorization_lock)

          {:ok, replacement_ciphertext} =
            Crypto.encrypt(
              "replacement-token",
              "credential:#{authorization.id}:access"
            )

          authorization
          |> OAuthAuthorization.changeset(%{access_token_ciphertext: replacement_ciphertext})
          |> Repo.update!()
        end)
      end)

    refute_receive :replacement_obtained_authorization_lock, 100
    send(checkout_pid, :finish_method_validation)

    assert {:ok, %SubmissionMethod{credential: {:oauth, "current-token"}}} =
             Task.await(checkout, 5_000)

    assert_receive :replacement_obtained_authorization_lock
    assert {:ok, %OAuthAuthorization{}} = Task.await(replacement, 5_000)
  end

  defp insert_gmail_method!(account, subject, opts \\ []) do
    address = Accounts.account_address(account)
    authorization_id = Ecto.UUID.generate()

    {:ok, access_ciphertext} =
      Crypto.encrypt(
        Keyword.get(opts, :access_token, "gmail-access-token"),
        "credential:#{authorization_id}:access"
      )

    {:ok, refresh_ciphertext} =
      Crypto.encrypt("gmail-refresh-token", "credential:#{authorization_id}:refresh")

    authorization =
      %OAuthAuthorization{id: authorization_id}
      |> OAuthAuthorization.changeset(%{
        account_id: account.id,
        provider: "gmail",
        provider_subject_id: subject,
        email_address: address,
        granted_scopes: Keyword.get(opts, :scopes, [GmailScopes.send()]),
        status: "connected",
        key_version: 1,
        access_token_ciphertext: access_ciphertext,
        refresh_token_ciphertext: refresh_ciphertext,
        token_expires_at:
          Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 3_600, :second))
      })
      |> Repo.insert!()

    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: account.id,
      oauth_authorization_id: authorization.id,
      kind: "gmail",
      email_address: address,
      status: Keyword.get(opts, :status, "connected"),
      enabled: Keyword.get(opts, :enabled, true)
    })
    |> Repo.insert!()
  end

  defp insert_gmail_receive!(account, authorization_id, subject) do
    %ReceiveMethod{}
    |> ReceiveMethod.changeset(%{
      account_id: account.id,
      oauth_authorization_id: authorization_id,
      kind: "gmail",
      provider_account_id: subject,
      email_address: Accounts.account_address(account),
      status: "connected",
      enabled: true,
      sync_enabled: true,
      granted_scopes: [GmailScopes.read()]
    })
    |> Repo.insert!()
  end

  defp insert_microsoft_method!(account, subject, opts) do
    address = Accounts.account_address(account)
    authorization_id = Ecto.UUID.generate()

    {:ok, access_ciphertext} =
      Crypto.encrypt(
        Keyword.get(opts, :access_token, "microsoft-access-token"),
        "credential:#{authorization_id}:access"
      )

    {:ok, refresh_ciphertext} =
      Crypto.encrypt(
        "microsoft-refresh-token",
        "credential:#{authorization_id}:refresh"
      )

    authorization =
      %OAuthAuthorization{id: authorization_id}
      |> OAuthAuthorization.changeset(%{
        account_id: account.id,
        provider: "microsoft",
        provider_subject_id: subject,
        email_address: address,
        granted_scopes: Keyword.get(opts, :scopes, [MicrosoftScopes.send()]),
        status: "connected",
        key_version: 1,
        access_token_ciphertext: access_ciphertext,
        refresh_token_ciphertext: refresh_ciphertext,
        token_expires_at:
          Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 3_600, :second))
      })
      |> Repo.insert!()

    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: account.id,
      oauth_authorization_id: authorization.id,
      kind: "microsoft",
      email_address: address,
      status: Keyword.get(opts, :status, "connected"),
      enabled: Keyword.get(opts, :enabled, true)
    })
    |> Repo.insert!()
  end

  defp insert_microsoft_receive!(account, authorization_id, subject) do
    %ReceiveMethod{}
    |> ReceiveMethod.changeset(%{
      account_id: account.id,
      oauth_authorization_id: authorization_id,
      kind: "microsoft",
      provider_account_id: subject,
      email_address: Accounts.account_address(account),
      status: "connected",
      enabled: true,
      sync_enabled: true,
      granted_scopes: [MicrosoftScopes.read()]
    })
    |> Repo.insert!()
  end

  defp insert_smtp_method!(account, password) do
    address = Accounts.account_address(account)

    method =
      %SendMethod{}
      |> SendMethod.changeset(%{
        account_id: account.id,
        kind: "smtp",
        email_address: address,
        status: "connected",
        enabled: true
      })
      |> Repo.insert!()

    {:ok, password_ciphertext} =
      Crypto.encrypt(password, "credential:#{method.id}:smtp_password")

    %SendCredential{}
    |> SendCredential.changeset(%{
      send_method_id: method.id,
      key_version: 1,
      password_ciphertext: password_ciphertext
    })
    |> Repo.insert!()

    %SmtpSettings{}
    |> SmtpSettings.changeset(%{
      send_method_id: method.id,
      host: "smtp.test",
      port: 587,
      tls_mode: "starttls",
      username: address
    })
    |> Repo.insert!()

    method
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)

  defp send_refresh_token do
    %Token{
      access_token: "send-refreshed-access",
      refresh_token: nil,
      expires_at: ~U[2026-08-11 04:00:00.000000Z],
      scopes: [GmailScopes.send()]
    }
  end

  defp repo_queries_during(fun) do
    handler_id = "submission-method-query-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          send(pid, {:submission_method_query, handler_id, metadata.query})
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

  defp received_repo_queries(handler_id, queries \\ []) do
    receive do
      {:submission_method_query, ^handler_id, query} ->
        received_repo_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end

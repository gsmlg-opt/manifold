defmodule Manifold.Connectors.SubmissionMethodTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, GmailScopes, SubmissionMethod}
  alias Manifold.Connectors.Provider.{Error, Identity, Page, RawMessage}

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    OAuthAuthorization,
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
    def refresh_token(_refresh_token, _config, opts),
      do: Keyword.fetch!(opts, :refresh_result)

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

    Application.put_env(:manifold_connectors, :adapters, gmail: FakeGmail)

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        client_id: "client-id-must-not-escape",
        client_secret: "client-secret-must-not-escape",
        authorization_url: "https://accounts.google.test/authorize",
        base_url: "https://gmail.test",
        req_options: [
          plug: {Req.Test, __MODULE__},
          headers: [{"cookie", "gmail-config-cookie-secret"}]
        ]
      ]
    )

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
    refute inspect(checked_out) =~ "gmail-config-cookie-secret"
    assert inspect(checked_out) =~ "config: :redacted"

    assert {:ok, %SubmissionMethod{credential: {:oauth, "other-token"}}} =
             Connectors.checkout_send_method(
               other_gmail.id,
               Accounts.account_address(other_account)
             )
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
                 assert {:ok, _disconnected} = Connectors.disconnect_send_method(gmail.id)
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

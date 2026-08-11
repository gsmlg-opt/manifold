defmodule Manifold.Connectors.SubmissionMethodTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, GmailScopes, SubmissionMethod}

  alias Manifold.Connectors.Schema.{
    OAuthAuthorization,
    SendCredential,
    SendMethod,
    SmtpSettings
  }

  alias Manifold.Core.Error
  alias Manifold.Repo

  setup do
    previous_key = Application.get_env(:manifold_connectors, :encryption_key)
    previous_providers = Application.get_env(:manifold_connectors, :providers)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        client_id: "client-id-must-not-escape",
        client_secret: "client-secret-must-not-escape",
        authorization_url: "https://accounts.google.test/authorize",
        base_url: "https://gmail.test",
        req_options: [plug: {Req.Test, __MODULE__}]
      ]
    )

    on_exit(fn ->
      restore_env(:encryption_key, previous_key)
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
    assert {:error, %Error{class: :permanent, reason: :send_method_required}} =
             Connectors.enabled_send_method(account.id)

    other_gmail = insert_gmail_method!(other_account, "other-subject")

    assert {:error, %Error{reason: :send_method_required}} =
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
    assert gmail_config[:req_options] == [plug: {Req.Test, __MODULE__}]
    refute Keyword.has_key?(gmail_config, :client_id)
    refute Keyword.has_key?(gmail_config, :client_secret)
    refute inspect(checked_out) =~ "sender-token"
    refute inspect(checked_out) =~ "client-secret-must-not-escape"

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

    assert {:error, %Error{class: :permanent, reason: :insufficient_provider_scope} = error} =
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

    assert {:error, %Error{class: :permanent, reason: :sender_address_mismatch}} =
             Connectors.checkout_send_method(gmail.id, "different@example.test")

    gmail
    |> SendMethod.changeset(%{enabled: false})
    |> Repo.update!()

    assert {:error, %Error{class: :permanent, reason: :send_method_required}} =
             Connectors.checkout_send_method(selected_id, Accounts.account_address(account))
  end

  test "checkout rejects disconnected and reconnect-required send methods", %{account: account} do
    disconnected =
      insert_gmail_method!(account, "sender-subject", enabled: false, status: "disconnected")

    assert {:error, %Error{class: :permanent, reason: :account_disconnected}} =
             Connectors.checkout_send_method(
               disconnected.id,
               Accounts.account_address(account)
             )

    reconnect =
      disconnected
      |> SendMethod.changeset(%{status: "reconnect_required", enabled: false})
      |> Repo.update!()

    assert {:error, %Error{class: :permanent, reason: :reauthorization_required}} =
             Connectors.checkout_send_method(reconnect.id, Accounts.account_address(account))
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

    credential = Repo.get_by!(SendCredential, send_method_id: smtp.id)
    {:ok, wrong_ciphertext} = Crypto.encrypt("wrong-aad-secret", "credential:other:smtp_password")

    credential
    |> SendCredential.changeset(%{password_ciphertext: wrong_ciphertext})
    |> Repo.update!()

    assert {:error, %Error{reason: :credential_authentication_failed} = error} =
             Connectors.checkout_send_method(smtp.id, Accounts.account_address(account))

    refute inspect(error) =~ "wrong-aad-secret"
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
        token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
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
end

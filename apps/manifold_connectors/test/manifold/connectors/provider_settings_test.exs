defmodule Manifold.Connectors.ProviderSettingsTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Crypto
  alias Manifold.Core.Error

  alias Manifold.Connectors.Schema.{
    OAuthAuthorization,
    OAuthProviderSetting,
    OAuthTransaction,
    ReceiveMethod,
    SendMethod
  }

  alias Manifold.Repo

  setup do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    on_exit(fn -> restore_env(:encryption_key, old_key) end)

    :ok
  end

  test "creates an encrypted provider setting and returns only safe views" do
    assert {:ok, missing} = Connectors.get_oauth_provider_setting("gmail")

    assert missing == %{
             provider: "gmail",
             client_id: nil,
             client_secret_configured?: false,
             status: :not_configured,
             lock_version: nil
           }

    assert {:ok, [^missing]} = Connectors.list_oauth_provider_settings()

    secret = "google-secret-do-not-expose"

    assert {:ok, view} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{
                 "client_id" => "  google-client  ",
                 "client_secret" => secret
               },
               expected_lock_version: nil
             )

    row = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    assert row.client_id == "google-client"
    refute row.client_secret_ciphertext =~ secret
    refute inspect(row) =~ secret
    refute inspect(view) =~ secret

    assert view == %{
             provider: "gmail",
             client_id: "google-client",
             client_secret_configured?: true,
             status: :configured,
             lock_version: row.lock_version
           }

    assert {:ok, ^secret} =
             Crypto.decrypt(
               row.client_secret_ciphertext,
               "oauth_provider_setting:#{row.id}:client_secret"
             )

    assert {:error, %Error{reason: :credential_authentication_failed}} =
             Crypto.decrypt(
               row.client_secret_ciphertext,
               "oauth_provider_setting:#{row.id}:wrong"
             )

    assert {:ok, [^view]} = Connectors.list_oauth_provider_settings()

    assert {:ok, credentials} =
             Manifold.Connectors.ProviderSettings.runtime_credentials("gmail")

    assert credentials.client_id == "google-client"
    assert credentials.client_secret == secret
    assert credentials.setting_id == row.id
    assert credentials.setting_lock_version == row.lock_version
    refute inspect(credentials) =~ secret
  end

  test "change returns a redacted changeset" do
    secret = "secret-that-must-not-be-inspected"

    changeset =
      Connectors.change_oauth_provider_setting("gmail", %{
        "client_id" => "client",
        "client_secret" => secret
      })

    assert %Ecto.Changeset{} = changeset
    refute inspect(changeset) =~ secret
    refute Map.get(changeset.changes, :client_secret) == secret
  end

  test "public form changesets structurally exclude plaintext and persisted ciphertext" do
    plaintext = "structural-plaintext-secret"
    assert {:ok, _view} = put_setting("client", "stored-secret")
    setting = Repo.get_by!(OAuthProviderSetting, provider: "gmail")

    change =
      Connectors.change_oauth_provider_setting("gmail", %{
        "client_id" => "client",
        "client_secret" => plaintext
      })

    assert %Ecto.Changeset{} = change
    refute_changeset_contains(change, [plaintext, setting.client_secret_ciphertext])

    assert {:error, %Ecto.Changeset{} = invalid} =
             Connectors.put_oauth_provider_setting("gmail", %{
               "client_id" => "",
               "client_secret" => plaintext
             })

    refute_changeset_contains(invalid, [plaintext, setting.client_secret_ciphertext])
  end

  test "list returns a generic temporary error when its repository is unavailable" do
    {:ok, failed_repo} =
      Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 1)

    Process.unlink(failed_repo)
    Supervisor.stop(failed_repo)
    previous_repo = Repo.put_dynamic_repo(failed_repo)

    try do
      assert {:error, %Error{class: :temporary, reason: :database_unavailable}} =
               Connectors.list_oauth_provider_settings()
    after
      Repo.put_dynamic_repo(previous_repo)
    end
  end

  test "same trimmed client ID with a blank secret is an exact no-op" do
    assert {:ok, first_view} = put_setting("client", "secret")
    before = Repo.get_by!(OAuthProviderSetting, provider: "gmail")

    %{authorization: authorization, receive: receive, send: send_method} =
      insert_oauth_family!("gmail", "noop")

    assert {:ok, ^first_view} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "  client  ", "client_secret" => " \t\n"},
               expected_lock_version: before.lock_version
             )

    after_setting = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    assert after_setting.client_secret_ciphertext == before.client_secret_ciphertext
    assert after_setting.lock_version == before.lock_version
    assert Repo.get!(OAuthAuthorization, authorization.id).status == "connected"
    assert Repo.get!(ReceiveMethod, receive.id).status == "connected"
    assert Repo.get!(SendMethod, send_method.id).status == "connected"
  end

  test "changing client ID without a new secret returns a safe validation error" do
    assert {:ok, _view} = put_setting("old-client", "old-secret")

    assert {:error, %Ecto.Changeset{} = changeset} =
             Connectors.put_oauth_provider_setting("gmail", %{
               "client_id" => "new-client",
               "client_secret" => ""
             })

    assert {"can't be blank", _} = changeset.errors[:client_secret]
    refute inspect(changeset) =~ "old-secret"
    assert Repo.get_by!(OAuthProviderSetting, provider: "gmail").client_id == "old-client"
  end

  test "secret rotation and client ID replacement advance the generation" do
    assert {:ok, initial} = put_setting("client-one", "secret-one")
    initial_row = Repo.get_by!(OAuthProviderSetting, provider: "gmail")

    assert {:ok, rotated} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "client-one", "client_secret" => "secret-two"}
             )

    rotated_row = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    assert rotated.lock_version == initial.lock_version + 1
    refute rotated_row.client_secret_ciphertext == initial_row.client_secret_ciphertext

    assert {:ok, replaced} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "client-two", "client_secret" => "secret-three"},
               expected_lock_version: rotated.lock_version
             )

    replaced_row = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    assert replaced.client_id == "client-two"
    assert replaced.lock_version == rotated.lock_version + 1

    assert {:ok, "secret-three"} =
             Crypto.decrypt(
               replaced_row.client_secret_ciphertext,
               "oauth_provider_setting:#{replaced_row.id}:client_secret"
             )
  end

  test "initial create with legacy grants reconnects only live provider dependencies" do
    gmail = insert_oauth_family!("gmail", "legacy")
    microsoft = insert_oauth_family!("microsoft", "other")
    disconnected = insert_oauth_family!("gmail", "disconnected", status: "disconnected")

    disconnected_methods =
      insert_oauth_family!("gmail", "disconnected-methods",
        authorization_status: "connected",
        method_status: "disconnected"
      )

    gmail_tokens = token_snapshot(gmail.authorization)
    microsoft_snapshot = family_snapshot(microsoft)
    disconnected_snapshot = family_snapshot(disconnected)

    disconnected_method_snapshot =
      {Repo.get!(ReceiveMethod, disconnected_methods.receive.id),
       Repo.get!(SendMethod, disconnected_methods.send.id)}

    transaction = insert_oauth_transaction!(gmail.authorization.account_id)

    assert {:ok, _view} = put_setting("client", "secret")

    assert_reconnect_required(gmail)
    assert token_snapshot(gmail.authorization) == gmail_tokens
    assert family_snapshot(microsoft) == microsoft_snapshot
    assert family_snapshot(disconnected) == disconnected_snapshot

    assert Repo.get!(OAuthAuthorization, disconnected_methods.authorization.id).status ==
             "reconnect_required"

    assert {Repo.get!(ReceiveMethod, disconnected_methods.receive.id),
            Repo.get!(SendMethod, disconnected_methods.send.id)} == disconnected_method_snapshot

    assert Repo.get!(OAuthTransaction, transaction.id).id == transaction.id
  end

  test "rotation reconnects live dependencies while preserving tokens and transaction snapshot" do
    assert {:ok, setting} = put_setting("client", "secret-one")
    row = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    gmail = insert_oauth_family!("gmail", "rotation")
    microsoft = insert_oauth_family!("microsoft", "rotation-other")
    transaction = insert_oauth_transaction!(gmail.authorization.account_id, row)
    tokens = token_snapshot(gmail.authorization)
    microsoft_snapshot = family_snapshot(microsoft)

    assert {:ok, rotated} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "client", "client_secret" => "secret-two"},
               expected_lock_version: setting.lock_version
             )

    assert_reconnect_required(gmail)
    assert token_snapshot(gmail.authorization) == tokens
    assert family_snapshot(microsoft) == microsoft_snapshot

    persisted_transaction = Repo.get!(OAuthTransaction, transaction.id)
    assert persisted_transaction.oauth_provider_setting_id == row.id
    assert persisted_transaction.oauth_provider_setting_lock_version == setting.lock_version
    assert persisted_transaction.oauth_provider_setting_lock_version != rotated.lock_version

    replacement_family = insert_oauth_family!("gmail", "client-id-replacement")

    assert {:ok, _replaced} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "replacement-client", "client_secret" => "secret-three"},
               expected_lock_version: rotated.lock_version
             )

    assert_reconnect_required(replacement_family)
  end

  test "removal applies lifecycle effects and deletes only the setting" do
    assert {:ok, setting} = put_setting("client", "secret")
    row = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    gmail = insert_oauth_family!("gmail", "remove")
    transaction = insert_oauth_transaction!(gmail.authorization.account_id, row)
    other_setting = insert_raw_setting!("future-provider", "future-client", "future-secret")
    tokens = token_snapshot(gmail.authorization)

    assert {:ok, removed_view} =
             Connectors.remove_oauth_provider_setting("gmail",
               expected_lock_version: setting.lock_version
             )

    assert removed_view.status == :not_configured
    assert is_nil(Repo.get_by(OAuthProviderSetting, provider: "gmail"))
    assert Repo.get!(OAuthProviderSetting, other_setting.id).provider == "future-provider"
    assert_reconnect_required(gmail)
    assert token_snapshot(gmail.authorization) == tokens
    assert Repo.get!(OAuthTransaction, transaction.id).id == transaction.id
  end

  test "corrupt ciphertext is reported as a generic configuration error" do
    assert {:ok, _view} = put_setting("client", "secret")

    OAuthProviderSetting
    |> where([setting], setting.provider == "gmail")
    |> Repo.update_all(set: [client_secret_ciphertext: <<1, 2, 3>>])

    assert {:ok, view} = Connectors.get_oauth_provider_setting("gmail")
    assert view.status == :configuration_error
    assert view.client_secret_configured?
    refute inspect(view) =~ "credential"

    assert {:error, %Error{reason: :oauth_provider_configuration_error} = error} =
             Manifold.Connectors.ProviderSettings.runtime_credentials("gmail")

    refute inspect(error) =~ "credential_authentication_failed"
    refute inspect(error) =~ "invalid_credential_envelope"
  end

  test "unsupported providers fail before persistence without creating atoms" do
    provider = "unsupported-#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end

    assert {:error, %Error{class: :permanent, reason: :unsupported_provider}} =
             Connectors.get_oauth_provider_setting(provider)

    assert {:error, %Error{class: :permanent, reason: :unsupported_provider}} =
             Connectors.put_oauth_provider_setting(provider, %{
               "client_id" => "client",
               "client_secret" => "secret"
             })

    assert {:error, %Error{class: :permanent, reason: :unsupported_provider}} =
             Connectors.remove_oauth_provider_setting(provider)

    assert_raise ArgumentError, fn -> String.to_existing_atom(provider) end
    assert Repo.aggregate(OAuthProviderSetting, :count) == 0
  end

  test "stale expected versions cannot overwrite or remove current credentials" do
    secret = "stale-secret-must-not-leak"
    assert {:ok, initial} = put_setting("client", "secret-one")

    assert {:ok, current} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "client", "client_secret" => "secret-two"},
               expected_lock_version: initial.lock_version
             )

    assert {:error, %Error{class: :permanent, reason: :stale_oauth_provider_setting} = error} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "attacker", "client_secret" => secret},
               expected_lock_version: initial.lock_version
             )

    refute inspect(error) =~ secret

    assert {:error, %Error{class: :permanent, reason: :stale_oauth_provider_setting}} =
             Connectors.remove_oauth_provider_setting("gmail",
               expected_lock_version: initial.lock_version
             )

    assert {:ok, ^current} = Connectors.get_oauth_provider_setting("gmail")
  end

  test "explicit nil expected version cannot overwrite a setting created after a missing snapshot" do
    assert {:ok, %{status: :not_configured, lock_version: nil}} =
             Connectors.get_oauth_provider_setting("gmail")

    assert {:ok, created} = put_setting("first-client", "first-secret")
    before = Repo.get_by!(OAuthProviderSetting, provider: "gmail")

    assert {:error, %Error{class: :permanent, reason: :stale_oauth_provider_setting}} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "second-client", "client_secret" => "second-secret"},
               expected_lock_version: nil
             )

    after_attempt = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    assert after_attempt.id == before.id
    assert after_attempt.client_id == before.client_id
    assert after_attempt.client_secret_ciphertext == before.client_secret_ciphertext
    assert after_attempt.lock_version == created.lock_version

    assert {:ok, "first-secret"} =
             Crypto.decrypt(
               after_attempt.client_secret_ciphertext,
               "oauth_provider_setting:#{after_attempt.id}:client_secret"
             )
  end

  test "explicit integer expected version is stale after the setting is removed" do
    assert {:ok, created} = put_setting("client", "secret")
    assert {:ok, %{status: :not_configured}} = Connectors.remove_oauth_provider_setting("gmail")

    assert {:error, %Error{class: :permanent, reason: :stale_oauth_provider_setting}} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "replacement", "client_secret" => "replacement-secret"},
               expected_lock_version: created.lock_version
             )

    assert is_nil(Repo.get_by(OAuthProviderSetting, provider: "gmail"))
  end

  defp put_setting(client_id, client_secret) do
    Connectors.put_oauth_provider_setting("gmail", %{
      "client_id" => client_id,
      "client_secret" => client_secret
    })
  end

  defp insert_oauth_family!(provider, suffix, opts \\ []) do
    status = Keyword.get(opts, :status, "connected")
    authorization_status = Keyword.get(opts, :authorization_status, status)
    method_status = Keyword.get(opts, :method_status, status)
    account = account_fixture!(suffix)
    authorization_id = Ecto.UUID.generate()

    {:ok, access_ciphertext} =
      Crypto.encrypt("#{provider}-#{suffix}-access", "credential:#{authorization_id}:access")

    {:ok, refresh_ciphertext} =
      Crypto.encrypt("#{provider}-#{suffix}-refresh", "credential:#{authorization_id}:refresh")

    authorization =
      %OAuthAuthorization{id: authorization_id}
      |> OAuthAuthorization.changeset(%{
        account_id: account.id,
        provider: provider,
        provider_subject_id: "#{provider}-subject-#{suffix}",
        email_address: Accounts.account_address(account),
        granted_scopes: ["scope"],
        status: authorization_status,
        key_version: 1,
        access_token_ciphertext: access_ciphertext,
        refresh_token_ciphertext: refresh_ciphertext,
        token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
        disconnected_at:
          if(authorization_status == "disconnected", do: DateTime.utc_now(), else: nil)
      })
      |> Repo.insert!()

    receive =
      %ReceiveMethod{}
      |> ReceiveMethod.changeset(%{
        account_id: account.id,
        oauth_authorization_id: authorization.id,
        kind: provider,
        provider_account_id: "#{provider}-subject-#{suffix}",
        email_address: Accounts.account_address(account),
        status: method_status,
        enabled: method_status != "disconnected",
        sync_enabled: true,
        granted_scopes: ["scope"],
        disconnected_at: if(method_status == "disconnected", do: DateTime.utc_now(), else: nil)
      })
      |> Repo.insert!()

    send_method =
      %SendMethod{}
      |> SendMethod.changeset(%{
        account_id: account.id,
        oauth_authorization_id: authorization.id,
        kind: provider,
        email_address: Accounts.account_address(account),
        status: method_status,
        enabled: method_status != "disconnected",
        disconnected_at: if(method_status == "disconnected", do: DateTime.utc_now(), else: nil)
      })
      |> Repo.insert!()

    %{authorization: authorization, receive: receive, send: send_method}
  end

  defp insert_oauth_transaction!(account_id, setting \\ nil) do
    setting_attrs =
      case setting do
        nil ->
          %{}

        setting ->
          %{
            oauth_provider_setting_id: setting.id,
            oauth_provider_setting_lock_version: setting.lock_version
          }
      end

    %OAuthTransaction{}
    |> OAuthTransaction.changeset(
      Map.merge(
        %{
          state_digest: :crypto.strong_rand_bytes(32),
          provider: "gmail",
          mailbox_id: account_id,
          purpose: "receive",
          required_scopes: ["scope"],
          pkce_verifier_ciphertext: <<1, 2, 3>>,
          redirect_uri: "https://mail.example.test/connectors/gmail/callback",
          expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
        },
        setting_attrs
      )
    )
    |> Repo.insert!()
  end

  defp insert_raw_setting!(provider, client_id, client_secret) do
    id = Ecto.UUID.generate()

    {:ok, ciphertext} =
      Crypto.encrypt(client_secret, "oauth_provider_setting:#{id}:client_secret")

    %OAuthProviderSetting{id: id}
    |> OAuthProviderSetting.changeset(%{
      provider: provider,
      client_id: client_id,
      client_secret_ciphertext: ciphertext,
      key_version: 1,
      lock_version: 1
    })
    |> Repo.insert!()
  end

  defp account_fixture!(suffix) do
    unique = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "#{suffix}-#{unique}.example.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "person"})
    Repo.preload(account, :domain)
  end

  defp assert_reconnect_required(family) do
    authorization = Repo.get!(OAuthAuthorization, family.authorization.id)
    receive = Repo.get!(ReceiveMethod, family.receive.id)
    send_method = Repo.get!(SendMethod, family.send.id)

    assert authorization.status == "reconnect_required"
    assert receive.status == "reconnect_required"
    refute receive.enabled
    refute receive.sync_enabled
    assert send_method.status == "reconnect_required"
    refute send_method.enabled
  end

  defp token_snapshot(authorization) do
    authorization = Repo.get!(OAuthAuthorization, authorization.id)

    {authorization.provider_subject_id, authorization.access_token_ciphertext,
     authorization.refresh_token_ciphertext}
  end

  defp family_snapshot(family) do
    {
      Repo.get!(OAuthAuthorization, family.authorization.id),
      Repo.get!(ReceiveMethod, family.receive.id),
      Repo.get!(SendMethod, family.send.id)
    }
  end

  defp refute_changeset_contains(changeset, sentinels) do
    Enum.each([changeset.data, changeset.changes, changeset.params], fn value ->
      Enum.each(sentinels, fn sentinel ->
        refute contains_binary?(value, sentinel)
      end)
    end)
  end

  defp contains_binary?(value, sentinel) when is_binary(value),
    do: :binary.match(value, sentinel) != :nomatch

  defp contains_binary?(value, sentinel) when is_struct(value),
    do: value |> Map.from_struct() |> contains_binary?(sentinel)

  defp contains_binary?(value, sentinel) when is_map(value),
    do:
      Enum.any?(value, fn {key, item} ->
        contains_binary?(key, sentinel) or contains_binary?(item, sentinel)
      end)

  defp contains_binary?(value, sentinel) when is_list(value),
    do: Enum.any?(value, &contains_binary?(&1, sentinel))

  defp contains_binary?(value, sentinel) when is_tuple(value),
    do: value |> Tuple.to_list() |> contains_binary?(sentinel)

  defp contains_binary?(_value, _sentinel), do: false

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

defmodule Manifold.Connectors.ProviderSettingsConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Manifold.Connectors
  alias Manifold.Connectors.ProviderSettings
  alias Manifold.Connectors.Schema.OAuthProviderSetting
  alias Manifold.Core.Error
  alias Manifold.Repo

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    old_key = Application.get_env(:manifold_connectors, :encryption_key)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Repo.delete_all(from(setting in OAuthProviderSetting, where: setting.provider == "gmail"))

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        Repo.delete_all(from(setting in OAuthProviderSetting, where: setting.provider == "gmail"))
      after
        Sandbox.checkin(Repo)
      end
    end)

    :ok
  end

  test "concurrent missing-row creates serialize and preserve the winner" do
    test_pid = self()
    gate = make_ref()

    first =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transaction(fn ->
            Repo.query!(
              "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
              ["oauth_provider_setting:gmail"]
            )

            assert :ok = ProviderSettings.lock_provider_for_transaction("gmail")
            send(test_pid, {:first_holds_provider_lock, self(), gate})

            receive do
              {:release_first, ^gate} -> :ok
            end

            Connectors.put_oauth_provider_setting(
              "gmail",
              %{"client_id" => "winner", "client_secret" => "winner-secret"},
              expected_lock_version: nil
            )
          end)
        end)
      end)

    assert_receive {:first_holds_provider_lock, first_pid, ^gate}, 5_000

    second =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          send(test_pid, {:second_attempting_create, self(), gate})

          Connectors.put_oauth_provider_setting(
            "gmail",
            %{"client_id" => "loser", "client_secret" => "loser-secret"},
            expected_lock_version: nil
          )
        end)
      end)

    assert_receive {:second_attempting_create, _second_pid, ^gate}, 5_000
    assert is_nil(Task.yield(second, 100))
    send(first_pid, {:release_first, gate})

    assert {:ok, {:ok, winner}} = Task.await(first, 5_000)

    assert {:error, %Error{class: :permanent, reason: :stale_oauth_provider_setting}} =
             Task.await(second, 5_000)

    setting = Repo.get_by!(OAuthProviderSetting, provider: "gmail")
    assert setting.client_id == "winner"
    assert setting.lock_version == winner.lock_version
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

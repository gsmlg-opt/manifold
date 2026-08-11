defmodule Manifold.Connectors.MicrosoftAuthorizationsTest do
  use Manifold.DataCase, async: false

  import Ecto.Query

  alias Manifold.Accounts
  alias Manifold.Accounts.Schema.Account
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, MicrosoftScopes, OAuthAuthorizations}
  alias Manifold.Connectors.Jobs.SyncAccount
  alias Manifold.Connectors.OAuth.Consumed
  alias Manifold.Connectors.Provider.{Identity, Page, RawMessage, Token}
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Connectors.Provider.SyncCursor, as: ProviderCursor

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    OAuthAuthorization,
    ReceiveMethod,
    SendMethod,
    SyncCursor
  }

  alias Manifold.Repo

  @now ~U[2026-08-12 01:00:00.000000Z]
  @expires_at ~U[2026-08-12 02:00:00.000000Z]
  @refresh_now ~U[2026-08-12 03:00:00.000000Z]
  @subject "microsoft-subject-1"

  defmodule FakeMicrosoft do
    @behaviour Manifold.Connectors.Provider

    @impl true
    def exchange_code(_code, _verifier, _redirect_uri, _config, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:exchange_required_scopes, Keyword.get(opts, :required_scopes)})
      end

      Keyword.fetch!(opts, :token)
    end

    @impl true
    def identity(_access_token, _config, opts), do: Keyword.fetch!(opts, :identity)

    @impl true
    def initial_cursors(access_token, _config, opts) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, :initial_cursors)
      end

      if gate = Keyword.get(opts, :cursor_gate) do
        test_pid = Keyword.fetch!(opts, :test_pid)
        send(test_pid, {:initial_cursors_started, self(), access_token})

        receive do
          {:release_cursors, ^gate} -> :ok
        end
      end

      Keyword.get(opts, :cursors, {:ok, [%ProviderCursor{scope: "mailbox", phase: "initial"}]})
    end

    @impl true
    def refresh_token(refresh_token, _config, opts) do
      if counter = Keyword.get(opts, :refresh_count) do
        Agent.update(counter, &(&1 + 1))
      end

      if test_pid = Keyword.get(opts, :test_pid) do
        send(
          test_pid,
          {:refresh_started, self(), refresh_token, Keyword.get(opts, :required_scopes)}
        )
      end

      if gate = Keyword.get(opts, :refresh_gate) do
        receive do
          {:release_refresh, ^gate} -> :ok
        end
      end

      Keyword.fetch!(opts, :refresh_result)
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

    Application.put_env(:manifold_connectors, :adapters, microsoft: FakeMicrosoft)

    Application.put_env(:manifold_connectors, :providers,
      microsoft: [
        client_id: "client",
        client_secret: "secret",
        authorization_url: "https://login.microsoft.test/authorize"
      ]
    )

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:adapters, old_adapters)
      restore_env(:providers, old_providers)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "microsoft#{suffix}.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "person"})
    account = Repo.preload(account, :domain)

    {:ok, account: account, address: Accounts.account_address(account)}
  end

  for {label, sequence, expected_scopes, receive_count, send_count} <- [
        {"new receive-only", [:receive], ~w(Mail.Read offline_access), 1, 0},
        {"new send-only", [:send], ~w(Mail.Send offline_access), 0, 1},
        {"receive-to-send incremental consent", [:receive, :send],
         ~w(Mail.Read Mail.Send offline_access), 1, 1},
        {"send-to-receive incremental consent", [:send, :receive],
         ~w(Mail.Read Mail.Send offline_access), 1, 1}
      ] do
    test "completion matrix: #{label}", %{account: account, address: address} do
      sequence = unquote(sequence)
      expected_scopes = Enum.sort(unquote(expected_scopes))

      sequence
      |> Enum.with_index()
      |> Enum.each(fn {purpose, index} ->
        scopes =
          if index == 0 do
            purpose_scopes(purpose)
          else
            expected_scopes
          end

        assert {:ok, method} =
                 complete(purpose, account, address,
                   required_scopes: scopes,
                   scopes: access_token_scopes(scopes),
                   refresh_token: if(index == 0, do: "refresh-secret", else: nil)
                 )

        assert method.account_id == account.id
        assert method.kind == "microsoft"
      end)

      assert [authorization] =
               Repo.all(
                 from(authorization in OAuthAuthorization,
                   where:
                     authorization.account_id == ^account.id and
                       authorization.provider == "microsoft"
                 )
               )

      assert authorization.granted_scopes == expected_scopes
      assert authorization.provider_subject_id == @subject
      assert authorization.email_address == address

      receive_query =
        from(method in ReceiveMethod,
          where: method.account_id == ^account.id and method.kind == "microsoft"
        )

      send_query =
        from(method in SendMethod,
          where: method.account_id == ^account.id and method.kind == "microsoft"
        )

      receive_methods = Repo.all(receive_query)
      assert Repo.aggregate(receive_query, :count) == unquote(receive_count)
      assert Repo.aggregate(send_query, :count) == unquote(send_count)

      case receive_methods do
        [%ReceiveMethod{} = receive] -> assert sync_job_count(receive.id) == 1
        [] -> assert Repo.aggregate(Oban.Job, :count) == 0
      end
    end
  end

  test "an incremental response without refresh_token retains existing ciphertext", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    before = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    assert {:ok, %SendMethod{}} =
             complete(:send, account, address,
               required_scopes: all_scopes(),
               scopes: access_token_scopes(all_scopes()),
               refresh_token: nil
             )

    after_upgrade = Repo.get!(OAuthAuthorization, before.id)
    assert after_upgrade.refresh_token_ciphertext == before.refresh_token_ciphertext
    assert after_upgrade.granted_scopes == all_scopes()
  end

  test "an incremental response with refresh_token rotates it atomically", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    before = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    assert {:ok, %SendMethod{}} =
             complete(:send, account, address,
               required_scopes: all_scopes(),
               scopes: access_token_scopes(all_scopes()),
               refresh_token: "rotated-refresh"
             )

    after_upgrade = Repo.get!(OAuthAuthorization, before.id)
    refute after_upgrade.refresh_token_ciphertext == before.refresh_token_ciphertext

    assert {:ok, "rotated-refresh"} =
             Crypto.decrypt(
               after_upgrade.refresh_token_ciphertext,
               "credential:#{after_upgrade.id}:refresh"
             )

    assert after_upgrade.granted_scopes == all_scopes()
  end

  test "subject mismatch leaves authorization and methods unchanged", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    before_authorization = authorization_snapshot(authorization)
    before_receive = receive_snapshot(receive)

    assert {:error, %{class: :permanent, reason: :provider_identity_mismatch}} =
             complete(:send, account, address,
               required_scopes: all_scopes(),
               scopes: access_token_scopes(all_scopes()),
               identity: %Identity{id: "different-subject", email_address: address}
             )

    assert authorization_snapshot(Repo.get!(OAuthAuthorization, authorization.id)) ==
             before_authorization

    assert receive_snapshot(Repo.get!(ReceiveMethod, receive.id)) == before_receive
    assert Repo.aggregate(SendMethod, :count) == 0
  end

  test "canonical address mismatch creates no authorization or method", %{
    account: account,
    address: address
  } do
    [local, domain] = String.split(address, "@", parts: 2)

    assert {:error, %{class: :permanent, reason: :provider_address_mismatch}} =
             complete(:receive, account, address,
               identity: %Identity{
                 id: @subject,
                 email_address: local <> "+alias@" <> domain
               }
             )

    assert Repo.aggregate(OAuthAuthorization, :count) == 0
    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(SendMethod, :count) == 0
  end

  test "a subject already bound to another account is rejected", %{
    account: account,
    address: address
  } do
    assert {:ok, _receive} = complete(:receive, account, address)
    {:ok, other_account} = Accounts.create_account(account.domain, %{local_part: "other"})
    other_account = Repo.preload(other_account, :domain)
    other_address = Accounts.account_address(other_account)

    assert {:error, %{class: :permanent, reason: :provider_identity_already_bound}} =
             complete(:receive, other_account, other_address,
               identity: %Identity{id: @subject, email_address: other_address}
             )

    assert Repo.aggregate(OAuthAuthorization, :count) == 1
    assert Repo.aggregate(ReceiveMethod, :count) == 1
  end

  test "a missing old or new required scope creates no method", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    before = authorization_snapshot(Repo.get!(OAuthAuthorization, receive.oauth_authorization_id))

    for scopes <- [[MicrosoftScopes.send()], [MicrosoftScopes.read()]] do
      assert {:error, %{class: :permanent, reason: :insufficient_provider_scope}} =
               complete(:send, account, address,
                 required_scopes: all_scopes(),
                 scopes: scopes
               )

      assert Repo.aggregate(SendMethod, :count) == 0

      assert authorization_snapshot(Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)) ==
               before
    end
  end

  test "an inactive account at callback creates no method", %{
    account: account,
    address: address
  } do
    account
    |> Account.changeset(%{active: false})
    |> Repo.update!()

    assert {:error, %{class: :permanent, reason: :mailbox_not_active}} =
             complete(:receive, account, address)

    assert Repo.aggregate(OAuthAuthorization, :count) == 0
    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(SendMethod, :count) == 0
  end

  test "a new Microsoft grant without a refresh token creates no authorization or method", %{
    account: account,
    address: address
  } do
    assert {:error, %{class: :permanent, reason: :missing_refresh_token}} =
             complete(:receive, account, address, refresh_token: nil)

    assert Repo.aggregate(OAuthAuthorization, :count) == 0
    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(SendMethod, :count) == 0
  end

  test "concurrent receive and send checkout performs one refresh request", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, _send_method} =
             complete(:send, account, address,
               required_scopes: all_scopes(),
               scopes: access_token_scopes(all_scopes()),
               refresh_token: nil
             )

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    {:ok, refresh_count} = Agent.start_link(fn -> 0 end)
    gate = make_ref()
    test_pid = self()

    refreshed = %Token{
      access_token: "rotated-access",
      refresh_token: nil,
      expires_at: ~U[2026-08-12 04:00:00.000000Z],
      scopes: access_token_scopes(all_scopes())
    }

    checkout = fn required_scope ->
      Connectors.checkout_oauth_access_token(authorization.id,
        required_scope: required_scope,
        now: @refresh_now,
        provider_opts: [
          refresh_count: refresh_count,
          refresh_gate: gate,
          refresh_result: {:ok, refreshed},
          test_pid: test_pid
        ]
      )
    end

    callers = [
      Task.async(fn -> checkout.(MicrosoftScopes.read()) end),
      Task.async(fn -> checkout.(MicrosoftScopes.send()) end)
    ]

    assert_receive {:refresh_started, refresher, "refresh-secret", required_scopes}
    assert Enum.sort(required_scopes) == all_scopes()
    refute_receive {:refresh_started, _, _, _}, 100
    send(refresher, {:release_refresh, gate})

    assert Enum.map(callers, &Task.await(&1, 5_000)) == [
             {:ok, "rotated-access"},
             {:ok, "rotated-access"}
           ]

    assert Agent.get(refresh_count, & &1) == 1
  end

  test "expired refresh accepts access-token scopes without offline_access and retains capability",
       %{
         account: account,
         address: address
       } do
    assert {:ok, receive} = complete(:receive, account, address)
    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    refreshed = %Token{
      access_token: "refreshed-access",
      refresh_token: "refreshed-rotation",
      expires_at: ~U[2026-08-12 04:00:00.000000Z],
      scopes: [MicrosoftScopes.read()]
    }

    assert {:ok, "refreshed-access"} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: MicrosoftScopes.read(),
               now: @refresh_now,
               provider_opts: [refresh_result: {:ok, refreshed}]
             )

    persisted = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted.granted_scopes == purpose_scopes(:receive)

    assert {:ok, "refreshed-rotation"} =
             Crypto.decrypt(
               persisted.refresh_token_ciphertext,
               "credential:#{authorization.id}:refresh"
             )
  end

  test "disconnecting receive leaves a healthy send reference and token ciphertext", %{
    account: account,
    address: address
  } do
    {receive, send_method, authorization} = complete_both(account, address)

    assert {:ok, disconnected_receive} =
             OAuthAuthorizations.disconnect_method(:receive, account.id, receive.id)

    assert disconnected_receive.status == "disconnected"

    persisted_send = Repo.get!(SendMethod, send_method.id)
    assert persisted_send.status == "connected"
    assert persisted_send.oauth_authorization_id == authorization.id

    persisted_authorization = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted_authorization.status == "connected"

    assert persisted_authorization.access_token_ciphertext ==
             authorization.access_token_ciphertext

    assert persisted_authorization.refresh_token_ciphertext ==
             authorization.refresh_token_ciphertext
  end

  test "disconnecting the final method erases ciphertext and disconnects authorization", %{
    account: account,
    address: address
  } do
    {receive, send_method, authorization} = complete_both(account, address)

    assert {:ok, %ReceiveMethod{status: "disconnected"}} =
             OAuthAuthorizations.disconnect_method(:receive, account.id, receive.id)

    assert {:ok, %SendMethod{status: "disconnected"}} =
             OAuthAuthorizations.disconnect_method(:send, account.id, send_method.id)

    disconnected = Repo.get!(OAuthAuthorization, authorization.id)
    assert disconnected.status == "disconnected"
    assert disconnected.provider_subject_id == @subject
    assert disconnected.email_address == address
    assert is_nil(disconnected.access_token_ciphertext)
    assert is_nil(disconnected.refresh_token_ciphertext)
    assert is_nil(disconnected.token_expires_at)
  end

  test "invalid_grant marks the authorization and both methods reconnect_required", %{
    account: account,
    address: address
  } do
    {receive, send_method, authorization} = complete_both(account, address)

    error = %ProviderError{
      class: :reconnect,
      code: :invalid_grant,
      message: "raw provider refresh error"
    }

    assert {:error,
            %ProviderError{
              class: :reconnect,
              code: :invalid_grant,
              message: "Microsoft authorization must be reconnected"
            }} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: MicrosoftScopes.send(),
               now: @refresh_now,
               provider_opts: [refresh_result: {:error, error}]
             )

    persisted = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted.status == "reconnect_required"
    assert persisted.last_error_code == "invalid_grant"
    assert persisted.last_error_message == "Microsoft authorization must be reconnected"

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

  test "receive add keeps a rotated refresh token when initial cursors fails", %{
    account: account,
    address: address
  } do
    assert {:ok, send_method} =
             complete(:send, account, address, scopes: access_token_scopes(all_scopes()))

    authorization = Repo.get!(OAuthAuthorization, send_method.oauth_authorization_id)
    events_before = Repo.aggregate(ConnectorEvent, :count)

    refreshed = %Token{
      access_token: "cursor-refresh-access",
      refresh_token: "cursor-refresh-rotation",
      expires_at: ~U[2026-08-12 04:00:00.000000Z],
      scopes: access_token_scopes(all_scopes())
    }

    cursor_error = %ProviderError{
      class: :temporary,
      code: :cursor_unavailable,
      message: "cursor initialization failed"
    }

    assert {:error, ^cursor_error} =
             OAuthAuthorizations.add_authorized_method(
               "microsoft",
               account.id,
               :receive,
               FakeMicrosoft,
               [],
               now: @refresh_now,
               provider_opts: [
                 refresh_result: {:ok, refreshed},
                 cursors: {:error, cursor_error}
               ]
             )

    persisted = Repo.get!(OAuthAuthorization, authorization.id)

    assert {:ok, "cursor-refresh-access"} =
             Crypto.decrypt(
               persisted.access_token_ciphertext,
               "credential:#{authorization.id}:access"
             )

    assert {:ok, "cursor-refresh-rotation"} =
             Crypto.decrypt(
               persisted.refresh_token_ciphertext,
               "credential:#{authorization.id}:refresh"
             )

    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(SyncCursor, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(ConnectorEvent, :count) == events_before
  end

  test "blocked cursor revalidation rejects a changed token generation", %{
    account: account,
    address: address
  } do
    assert {:ok, send_method} =
             complete(:send, account, address, scopes: access_token_scopes(all_scopes()))

    authorization = Repo.get!(OAuthAuthorization, send_method.oauth_authorization_id)
    events_before = Repo.aggregate(ConnectorEvent, :count)
    gate = make_ref()
    test_pid = self()

    assert {:ok, superseding_ciphertext} =
             Crypto.encrypt(
               "superseding-access",
               "credential:#{authorization.id}:access"
             )

    add_task =
      Task.async(fn ->
        OAuthAuthorizations.add_authorized_method(
          "microsoft",
          account.id,
          :receive,
          FakeMicrosoft,
          [],
          now: @now,
          provider_opts: [cursor_gate: gate, test_pid: test_pid]
        )
      end)

    assert_receive {:initial_cursors_started, cursor_process, "access-secret"}

    mutation_task =
      Task.async(fn ->
        authorization.id
        |> then(&Repo.get!(OAuthAuthorization, &1))
        |> OAuthAuthorization.changeset(%{
          access_token_ciphertext: superseding_ciphertext,
          token_expires_at: ~U[2026-08-12 05:00:00.000000Z]
        })
        |> Repo.update!()
      end)

    mutated =
      case Task.yield(mutation_task, 1_000) do
        {:ok, %OAuthAuthorization{} = mutated} ->
          mutated

        nil ->
          send(cursor_process, {:release_cursors, gate})
          _mutation = Task.await(mutation_task, 5_000)
          _add_result = Task.await(add_task, 5_000)
          flunk("authorization mutation remained blocked during cursor provider I/O")
      end

    send(cursor_process, {:release_cursors, gate})

    assert {:error, %{class: :permanent, reason: :stale_oauth_authorization} = error} =
             Task.await(add_task, 5_000)

    refute inspect(error) =~ "access-secret"
    refute inspect(error) =~ "superseding-access"
    assert mutated.lock_version > authorization.lock_version

    assert {:ok, "superseding-access"} =
             Crypto.decrypt(
               Repo.get!(OAuthAuthorization, authorization.id).access_token_ciphertext,
               "credential:#{authorization.id}:access"
             )

    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(SyncCursor, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(ConnectorEvent, :count) == events_before
  end

  test "blocked receive add cannot undo a concurrent receive disconnect", %{
    account: account,
    address: address
  } do
    {receive, send_method, authorization} = complete_both(account, address)
    reconnectable = mark_receive_reconnectable!(receive)
    cursor_ids_before = sync_cursor_ids(receive.id)
    jobs_before = sync_job_count(receive.id)
    events_before = Repo.aggregate(ConnectorEvent, :count)
    gate = make_ref()

    {add_task, cursor_process} = start_blocked_receive_add(account, gate)

    assert {:ok, %ReceiveMethod{status: "disconnected"}} =
             OAuthAuthorizations.disconnect_method(:receive, account.id, reconnectable.id)

    send(cursor_process, {:release_cursors, gate})

    assert {:error, %{class: :permanent, reason: :stale_oauth_authorization}} =
             Task.await(add_task, 5_000)

    persisted_authorization = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted_authorization.status == "connected"
    assert persisted_authorization.lock_version > authorization.lock_version

    assert persisted_authorization.access_token_ciphertext ==
             authorization.access_token_ciphertext

    assert persisted_authorization.refresh_token_ciphertext ==
             authorization.refresh_token_ciphertext

    assert Repo.get!(ReceiveMethod, receive.id).status == "disconnected"
    assert Repo.get!(SendMethod, send_method.id).status == "connected"
    assert sync_cursor_ids(receive.id) == cursor_ids_before
    assert sync_job_count(receive.id) == jobs_before
    assert Repo.aggregate(ConnectorEvent, :count) == events_before + 1
  end

  test "blocked receive add cannot recreate a concurrently deleted receive method", %{
    account: account,
    address: address
  } do
    {receive, send_method, authorization} = complete_both(account, address)
    reconnectable = mark_receive_reconnectable!(receive)
    events_before = Repo.aggregate(ConnectorEvent, :count)
    gate = make_ref()

    {add_task, cursor_process} = start_blocked_receive_add(account, gate)

    assert {:ok, %ReceiveMethod{id: deleted_id}} =
             OAuthAuthorizations.delete_receive_method(reconnectable.id)

    assert deleted_id == receive.id
    send(cursor_process, {:release_cursors, gate})

    assert {:error, %{class: :permanent, reason: :stale_oauth_authorization}} =
             Task.await(add_task, 5_000)

    persisted_authorization = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted_authorization.status == "connected"
    assert persisted_authorization.lock_version > authorization.lock_version

    assert persisted_authorization.access_token_ciphertext ==
             authorization.access_token_ciphertext

    assert persisted_authorization.refresh_token_ciphertext ==
             authorization.refresh_token_ciphertext

    assert Repo.get!(SendMethod, send_method.id).status == "connected"
    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(SyncCursor, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(ConnectorEvent, :count) == events_before + 1
  end

  test "blocked receive add preserves a competing method enabled during cursor discovery", %{
    account: account,
    address: address
  } do
    assert {:ok, send_method} =
             complete(:send, account, address, scopes: access_token_scopes(all_scopes()))

    other_receive = insert_other_receive!(account.id, address, enabled: false)
    events_before = Repo.aggregate(ConnectorEvent, :count)
    gate = make_ref()

    {add_task, cursor_process} = start_blocked_receive_add(account, gate)

    enabled_receive =
      other_receive
      |> ReceiveMethod.changeset(%{enabled: true})
      |> Repo.update!()

    send(cursor_process, {:release_cursors, gate})

    assert {:error, %{class: :permanent, reason: :stale_oauth_authorization}} =
             Task.await(add_task, 5_000)

    assert receive_snapshot(Repo.get!(ReceiveMethod, other_receive.id)) ==
             receive_snapshot(enabled_receive)

    assert Repo.aggregate(
             from(method in ReceiveMethod, where: method.kind == "microsoft"),
             :count
           ) == 0

    assert Repo.get!(SendMethod, send_method.id).status == "connected"
    assert Repo.aggregate(SyncCursor, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(ConnectorEvent, :count) == events_before
  end

  test "simultaneous receive adds from one lifecycle snapshot converge once", %{
    account: account,
    address: address
  } do
    assert {:ok, send_method} =
             complete(:send, account, address, scopes: access_token_scopes(all_scopes()))

    events_before = Repo.aggregate(ConnectorEvent, :count)
    gate = make_ref()

    {first_task, first_cursor_process} = start_blocked_receive_add(account, gate)
    {second_task, second_cursor_process} = start_blocked_receive_add(account, gate)

    send(first_cursor_process, {:release_cursors, gate})
    send(second_cursor_process, {:release_cursors, gate})

    results = [Task.await(first_task, 5_000), Task.await(second_task, 5_000)]

    assert Enum.count(results, &match?({:ok, %ReceiveMethod{}}, &1)) == 1

    assert Enum.count(
             results,
             &match?(
               {:error, %{class: :permanent, reason: :stale_oauth_authorization}},
               &1
             )
           ) == 1

    assert [%ReceiveMethod{status: "connected", enabled: true, sync_enabled: true} = receive] =
             Repo.all(ReceiveMethod)

    assert Repo.get!(SendMethod, send_method.id).status == "connected"
    assert Repo.aggregate(SyncCursor, :count) == 1
    assert sync_job_count(receive.id) == 1
    assert Repo.aggregate(ConnectorEvent, :count) == events_before + 1
  end

  test "adding an already healthy active receive method returns before cursor discovery", %{
    account: account,
    address: address
  } do
    assert {:ok, %ReceiveMethod{} = receive} = complete(:receive, account, address)

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    receive_before = receive_snapshot(Repo.get!(ReceiveMethod, receive.id))
    authorization_before = authorization_snapshot(authorization)
    cursor_ids_before = sync_cursor_ids(receive.id)
    events_before = Repo.aggregate(ConnectorEvent, :count)
    test_pid = self()

    assert {:ok, %ReceiveMethod{id: receive_id}} =
             OAuthAuthorizations.add_authorized_method(
               "microsoft",
               account.id,
               :receive,
               FakeMicrosoft,
               [],
               now: @refresh_now,
               provider_opts: [test_pid: test_pid]
             )

    assert receive_id == receive.id
    refute_receive :initial_cursors, 100
    assert receive_snapshot(Repo.get!(ReceiveMethod, receive.id)) == receive_before

    assert authorization_snapshot(Repo.get!(OAuthAuthorization, authorization.id)) ==
             authorization_before

    assert sync_cursor_ids(receive.id) == cursor_ids_before
    assert sync_job_count(receive.id) == 1
    assert Repo.aggregate(ConnectorEvent, :count) == events_before
  end

  test "an active receive with a stale authorization binding rejects before provider I/O", %{
    account: account,
    address: address
  } do
    assert {:ok, %ReceiveMethod{} = receive} = complete(:receive, account, address)

    misbound =
      receive
      |> ReceiveMethod.changeset(%{provider_account_id: "different-microsoft-subject"})
      |> Repo.update!()

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    cursor_ids_before = sync_cursor_ids(receive.id)
    events_before = Repo.aggregate(ConnectorEvent, :count)
    test_pid = self()

    assert {:error, %{class: :permanent, reason: :stale_oauth_authorization}} =
             OAuthAuthorizations.add_authorized_method(
               "microsoft",
               account.id,
               :receive,
               FakeMicrosoft,
               [],
               now: @refresh_now,
               provider_opts: [test_pid: test_pid]
             )

    refute_receive :initial_cursors, 100
    assert receive_snapshot(Repo.get!(ReceiveMethod, receive.id)) == receive_snapshot(misbound)
    assert sync_cursor_ids(receive.id) == cursor_ids_before
    assert sync_job_count(receive.id) == 1
    assert Repo.aggregate(ConnectorEvent, :count) == events_before

    assert authorization_snapshot(Repo.get!(OAuthAuthorization, authorization.id)) ==
             authorization_snapshot(authorization)
  end

  test "receive deletion locks cursors before the receive method", %{
    account: account,
    address: address
  } do
    {receive, _send_method, _authorization} = complete_both(account, address)

    queries =
      repo_queries_during(fn ->
        assert {:ok, %ReceiveMethod{id: receive_id}} =
                 OAuthAuthorizations.delete_receive_method(receive.id)

        assert receive_id == receive.id
      end)

    cursor_lock = cursor_lock_index(queries)
    receive_method_lock = receive_method_lock_index(queries)

    assert is_integer(cursor_lock)
    assert is_integer(receive_method_lock)
    assert cursor_lock < receive_method_lock
  end

  test "adding Microsoft Send disables only the previously enabled send method", %{
    account: account,
    address: address
  } do
    other_send = insert_other_send!(account.id, address)

    assert {:ok, receive} =
             complete(:receive, account, address, scopes: access_token_scopes(all_scopes()))

    assert Repo.get!(SendMethod, other_send.id).enabled

    assert {:ok, %SendMethod{} = microsoft_send} =
             OAuthAuthorizations.add_authorized_method(
               "microsoft",
               account.id,
               :send,
               FakeMicrosoft,
               [],
               now: @now
             )

    assert microsoft_send.enabled
    refute Repo.get!(SendMethod, other_send.id).enabled
    assert Repo.get!(ReceiveMethod, receive.id).enabled
    assert sync_job_count(receive.id) == 1
  end

  test "adding Microsoft Receive preserves the independent enabled send method", %{
    account: account,
    address: address
  } do
    other_receive = insert_other_receive!(account.id, address)

    assert {:ok, send_method} =
             complete(:send, account, address, scopes: access_token_scopes(all_scopes()))

    assert Repo.get!(ReceiveMethod, other_receive.id).enabled

    assert {:ok, %ReceiveMethod{} = microsoft_receive} =
             OAuthAuthorizations.add_authorized_method(
               "microsoft",
               account.id,
               :receive,
               FakeMicrosoft,
               [],
               now: @now
             )

    assert microsoft_receive.enabled
    refute Repo.get!(ReceiveMethod, other_receive.id).enabled
    assert Repo.get!(SendMethod, send_method.id).enabled
    assert sync_job_count(microsoft_receive.id) == 1
  end

  defp complete_both(account, address) do
    assert {:ok, receive} = complete(:receive, account, address)

    assert {:ok, send_method} =
             complete(:send, account, address,
               required_scopes: all_scopes(),
               scopes: access_token_scopes(all_scopes()),
               refresh_token: nil
             )

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    {receive, send_method, authorization}
  end

  defp complete(purpose, account, address, opts \\ []) do
    required_scopes = Keyword.get(opts, :required_scopes, purpose_scopes(purpose))

    consumed = %Consumed{
      provider: "microsoft",
      mailbox_id: account.id,
      purpose: purpose,
      required_scopes: required_scopes,
      redirect_uri: "https://mail.example.test/connectors/microsoft/callback",
      pkce_verifier: "verifier-secret"
    }

    token = %Token{
      access_token: Keyword.get(opts, :access_token, "access-secret"),
      refresh_token: Keyword.get(opts, :refresh_token, "refresh-secret"),
      expires_at: Keyword.get(opts, :expires_at, @expires_at),
      scopes: Keyword.get(opts, :scopes, access_token_scopes(required_scopes))
    }

    identity =
      Keyword.get(opts, :identity, %Identity{
        id: @subject,
        email_address: address
      })

    provider_opts =
      Keyword.merge(
        [token: {:ok, token}, identity: {:ok, identity}],
        Keyword.get(opts, :provider_opts, [])
      )

    Connectors.complete_authorization(
      "microsoft",
      Keyword.get(opts, :code, "authorization-code-secret"),
      consumed,
      now: @now,
      provider_opts: provider_opts
    )
  end

  defp purpose_scopes(:receive),
    do: Enum.sort([MicrosoftScopes.read(), MicrosoftScopes.offline()])

  defp purpose_scopes(:send),
    do: Enum.sort([MicrosoftScopes.send(), MicrosoftScopes.offline()])

  defp all_scopes,
    do: Enum.sort([MicrosoftScopes.read(), MicrosoftScopes.send(), MicrosoftScopes.offline()])

  defp access_token_scopes(scopes) do
    scopes
    |> Enum.reject(&(&1 == MicrosoftScopes.offline()))
    |> Enum.sort()
  end

  defp authorization_snapshot(authorization) do
    Map.take(authorization, [
      :account_id,
      :provider,
      :provider_subject_id,
      :email_address,
      :granted_scopes,
      :status,
      :access_token_ciphertext,
      :refresh_token_ciphertext,
      :token_expires_at,
      :last_error_class,
      :last_error_code,
      :last_error_message,
      :disconnected_at,
      :lock_version
    ])
  end

  defp receive_snapshot(receive) do
    Map.take(receive, [
      :account_id,
      :oauth_authorization_id,
      :kind,
      :provider_account_id,
      :email_address,
      :status,
      :enabled,
      :sync_enabled,
      :granted_scopes,
      :lock_version
    ])
  end

  defp insert_other_receive!(account_id, address, opts \\ []) do
    %ReceiveMethod{}
    |> ReceiveMethod.changeset(%{
      account_id: account_id,
      kind: "imap",
      provider_account_id: "imap:#{address}",
      email_address: address,
      status: "connected",
      enabled: Keyword.get(opts, :enabled, true),
      sync_enabled: true,
      granted_scopes: []
    })
    |> Repo.insert!()
  end

  defp mark_receive_reconnectable!(receive) do
    receive
    |> ReceiveMethod.changeset(%{
      status: "failed",
      enabled: false,
      sync_enabled: false
    })
    |> Repo.update!()
  end

  defp start_blocked_receive_add(account, gate) do
    test_pid = self()

    task =
      Task.async(fn ->
        OAuthAuthorizations.add_authorized_method(
          "microsoft",
          account.id,
          :receive,
          FakeMicrosoft,
          [],
          now: @now,
          provider_opts: [cursor_gate: gate, test_pid: test_pid]
        )
      end)

    assert_receive {:initial_cursors_started, cursor_process, "access-secret"}
    {task, cursor_process}
  end

  defp sync_cursor_ids(receive_method_id) do
    SyncCursor
    |> where([cursor], cursor.external_account_id == ^receive_method_id)
    |> order_by([cursor], asc: cursor.id)
    |> select([cursor], cursor.id)
    |> Repo.all()
  end

  defp repo_queries_during(fun) do
    handler_id = "microsoft-lifecycle-query-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          send(pid, {:microsoft_lifecycle_query, handler_id, metadata.query})
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
      {:microsoft_lifecycle_query, ^handler_id, query} ->
        received_repo_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp cursor_lock_index(queries) do
    Enum.find_index(queries, fn query ->
      String.contains?(query, ~s(FROM "connector_sync_cursors")) and
        String.contains?(query, "FOR UPDATE")
    end)
  end

  defp receive_method_lock_index(queries) do
    Enum.find_index(queries, fn query ->
      String.contains?(query, ~s(FROM "connector_accounts")) and
        String.contains?(query, "FOR UPDATE")
    end)
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

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

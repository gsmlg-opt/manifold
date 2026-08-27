defmodule Manifold.Connectors.MicrosoftAuthorizationsTest do
  use Manifold.DataCase, async: false

  import Ecto.Query

  alias Manifold.Accounts
  alias Manifold.Accounts.Schema.Account
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, MicrosoftScopes, OAuth, OAuthAuthorizations}
  alias Manifold.Connectors.Jobs.SyncAccount
  alias Manifold.Connectors.OAuth.Consumed
  alias Manifold.Connectors.Provider.{Identity, Page, RawMessage, Token}
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Connectors.Provider.MicrosoftGraph
  alias Manifold.Connectors.Provider.SyncCursor, as: ProviderCursor
  alias Manifold.Connectors.View.OAuthMethodSetup

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    OAuthAuthorization,
    OAuthProviderSetting,
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
    def exchange_code(_code, _verifier, _redirect_uri, config, opts) do
      notify_config(opts, :exchange_config, config)

      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {:exchange_required_scopes, Keyword.get(opts, :required_scopes)})
      end

      if gate = Keyword.get(opts, :exchange_gate) do
        test_pid = Keyword.fetch!(opts, :test_pid)
        send(test_pid, {:oauth_code_exchange_started, self(), gate})

        receive do
          {:release_oauth_exchange, ^gate} -> :ok
        end
      end

      Keyword.fetch!(opts, :token)
    end

    @impl true
    def identity(_access_token, config, opts) do
      notify_config(opts, :identity_config, config)
      Keyword.fetch!(opts, :identity)
    end

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

    defp notify_config(opts, event, config) do
      if test_pid = Keyword.get(opts, :test_pid) do
        send(test_pid, {event, config})
      end
    end
  end

  defmodule FailingMicrosoft do
    @behaviour Manifold.Connectors.Provider

    @impl true
    defdelegate exchange_code(code, verifier, redirect_uri, config, opts), to: FakeMicrosoft

    @impl true
    defdelegate identity(access_token, config, opts), to: FakeMicrosoft

    @impl true
    def initial_cursors(_access_token, _config, _opts) do
      {:error,
       %ProviderError{
         class: :temporary,
         code: :provider_unavailable,
         message: "Microsoft Graph is temporarily unavailable",
         retry_after_seconds: 30
       }}
    end

    @impl true
    defdelegate refresh_token(refresh_token, config, opts), to: FakeMicrosoft

    @impl true
    defdelegate sync_page(access_token, cursor, config, opts), to: FakeMicrosoft

    @impl true
    defdelegate fetch_raw(access_token, message_id, config, opts), to: FakeMicrosoft
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
        authorization_url: "https://login.microsoft.test/authorize",
        token_url: "https://login.microsoft.test/token",
        userinfo_url: "https://graph.microsoft.test/oidc/userinfo",
        base_url: "https://graph.microsoft.test/v1.0"
      ]
    )

    assert {:ok, microsoft_setting_view} =
             Connectors.put_oauth_provider_setting("microsoft", %{
               "client_id" => "db-client",
               "client_secret" => "db-secret"
             })

    microsoft_setting = Repo.get_by!(OAuthProviderSetting, provider: "microsoft")

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:adapters, old_adapters)
      restore_env(:providers, old_providers)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "microsoft#{suffix}.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "person"})
    account = Repo.preload(account, :domain)

    {:ok,
     account: account,
     address: Accounts.account_address(account),
     microsoft_setting: microsoft_setting,
     microsoft_setting_view: microsoft_setting_view}
  end

  test "unchanged Microsoft setting generation completes through the public context", %{
    account: account,
    address: address,
    microsoft_setting: microsoft_setting
  } do
    consumed = start_and_consume_microsoft!(account.id, :receive)

    assert consumed.oauth_provider_setting_id == microsoft_setting.id
    assert consumed.oauth_provider_setting_lock_version == microsoft_setting.lock_version

    assert {:ok, %ReceiveMethod{status: "connected"}} =
             Connectors.complete_authorization("microsoft", "authorization-code", consumed,
               now: @now,
               provider_opts: completion_provider_opts(address, :receive, test_pid: self())
             )

    assert_receive {:exchange_config, config}
    assert_receive {:identity_config, ^config}
    assert config[:client_id] == "db-client"
    assert config[:client_secret] == "db-secret"
  end

  test "rotating the Microsoft setting during exchange rejects completion without persistence", %{
    account: account,
    address: address,
    microsoft_setting_view: microsoft_setting_view
  } do
    consumed = start_and_consume_microsoft!(account.id, :receive)
    test_pid = self()
    gate = make_ref()

    completion =
      Task.async(fn ->
        Connectors.complete_authorization("microsoft", "authorization-code", consumed,
          now: @now,
          provider_opts:
            completion_provider_opts(address, :receive,
              test_pid: test_pid,
              exchange_gate: gate
            )
        )
      end)

    assert_receive {:oauth_code_exchange_started, completion_pid, ^gate}, 5_000

    assert {:ok, _rotated} =
             Connectors.put_oauth_provider_setting(
               "microsoft",
               %{"client_id" => "rotated-client", "client_secret" => "rotated-secret"},
               expected_lock_version: microsoft_setting_view.lock_version
             )

    send(completion_pid, {:release_oauth_exchange, gate})

    assert {:error, %{class: :permanent, reason: :provider_configuration_changed}} =
             Task.await(completion, 5_000)

    assert Repo.aggregate(OAuthAuthorization, :count) == 0
    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(SendMethod, :count) == 0
    assert Repo.aggregate(ConnectorEvent, :count) == 0
    assert Repo.aggregate(SyncCursor, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
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

  test "Microsoft OAuth lifecycle telemetry is provider-aware and content-free", %{
    account: account,
    address: address
  } do
    events = [
      [:manifold, :connectors, :oauth, :start, :stop],
      [:manifold, :connectors, :oauth, :complete, :stop],
      [:manifold, :connectors, :oauth, :refresh, :stop]
    ]

    attach_oauth_telemetry(events)

    redirect_uri =
      "https://mail.example.test/connectors/microsoft/callback?marker=telemetry-address-sentinel"

    assert {:ok, _authorization} =
             OAuth.start("microsoft", account.id, redirect_uri, purpose: :receive)

    start_telemetry = assert_oauth_telemetry(:start, :started)

    assert start_telemetry.metadata == %{
             account_id: account.id,
             provider: "microsoft",
             method_kind: "microsoft",
             outcome: :started
           }

    assert {:ok, receive} =
             complete(:receive, account, address,
               code: "telemetry-authorization-code-sentinel",
               access_token: "telemetry-access-token-sentinel",
               refresh_token: "telemetry-refresh-token-sentinel"
             )

    connected = assert_oauth_telemetry(:complete, :connected)

    assert connected.metadata == %{
             account_id: account.id,
             authorization_id: receive.oauth_authorization_id,
             method_id: receive.id,
             provider: "microsoft",
             method_kind: "microsoft",
             outcome: :connected
           }

    assert {:ok, send_method} =
             complete(:send, account, address,
               access_token: "telemetry-upgrade-token-sentinel",
               refresh_token: nil,
               required_scopes: all_scopes(),
               scopes: access_token_scopes(all_scopes())
             )

    upgraded = assert_oauth_telemetry(:complete, :scope_upgraded)

    assert upgraded.metadata == %{
             account_id: account.id,
             authorization_id: receive.oauth_authorization_id,
             method_id: send_method.id,
             provider: "microsoft",
             method_kind: "microsoft",
             outcome: :scope_upgraded
           }

    rejected_error = %ProviderError{
      class: :permanent,
      code: :"telemetry-subject-sentinel",
      message: "telemetry-body-sentinel"
    }

    assert {:error, %{reason: :"telemetry-subject-sentinel"}} =
             complete(:send, account, address, provider_opts: [token: {:error, rejected_error}])

    rejected = assert_oauth_telemetry(:complete, :error)

    assert rejected.metadata == %{
             account_id: account.id,
             provider: "microsoft",
             method_kind: "microsoft",
             outcome: :error,
             error_code: :connector_operation_failed
           }

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    refreshed_token = %Token{
      access_token: "telemetry-refreshed-access-sentinel",
      refresh_token: "telemetry-refreshed-refresh-sentinel",
      expires_at: ~U[2026-08-12 04:00:00.000000Z],
      scopes: access_token_scopes(all_scopes())
    }

    assert {:ok, "telemetry-refreshed-access-sentinel"} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: MicrosoftScopes.send(),
               now: @refresh_now,
               provider_opts: [refresh_result: {:ok, refreshed_token}]
             )

    refreshed = assert_oauth_telemetry(:refresh, :refreshed)

    assert refreshed.metadata == %{
             account_id: account.id,
             authorization_id: authorization.id,
             provider: "microsoft",
             method_kind: "microsoft",
             outcome: :refreshed
           }

    reconnect_error_code = :"telemetry-reconnect-code-sentinel"

    reconnect_error = %ProviderError{
      class: :reconnect,
      code: reconnect_error_code,
      message: "telemetry-bcc-sentinel"
    }

    assert {:error, %ProviderError{code: ^reconnect_error_code}} =
             Connectors.checkout_oauth_access_token(authorization.id,
               required_scope: MicrosoftScopes.send(),
               now: ~U[2026-08-12 05:00:00.000000Z],
               provider_opts: [refresh_result: {:error, reconnect_error}]
             )

    reconnect = assert_oauth_telemetry(:refresh, :reconnect_required)

    assert reconnect.metadata == %{
             account_id: account.id,
             authorization_id: authorization.id,
             provider: "microsoft",
             method_kind: "microsoft",
             outcome: :reconnect_required,
             error_code: :connector_operation_failed
           }

    reconnect_event =
      Repo.get_by!(ConnectorEvent,
        oauth_authorization_id: authorization.id,
        event_type: "reconnect_required"
      )

    assert reconnect_event.metadata == %{
             "direction" => "authorization",
             "error_class" => "reconnect",
             "error_code" => "connector_operation_failed",
             "provider" => "microsoft"
           }

    sentinels = [
      "telemetry-address-sentinel",
      "telemetry-authorization-code-sentinel",
      "telemetry-access-token-sentinel",
      "telemetry-refresh-token-sentinel",
      "telemetry-upgrade-token-sentinel",
      "telemetry-subject-sentinel",
      "telemetry-body-sentinel",
      "telemetry-refreshed-access-sentinel",
      "telemetry-refreshed-refresh-sentinel",
      "telemetry-reconnect-code-sentinel",
      "telemetry-bcc-sentinel"
    ]

    inspected_safe_surfaces =
      inspect(%{
        telemetry: [start_telemetry, connected, upgraded, rejected, refreshed, reconnect],
        connector_events: Enum.map(Repo.all(ConnectorEvent), & &1.metadata),
        job_args: Enum.map(Repo.all(Oban.Job), & &1.args)
      })

    Enum.each(sentinels, &refute(inspected_safe_surfaces =~ &1))
  end

  test "token checkout rejects malformed authorization IDs without a cast exception" do
    assert {:error, %{class: :permanent, reason: :authorization_not_found}} =
             Connectors.checkout_oauth_access_token(
               "not-an-authorization-id",
               required_scope: MicrosoftScopes.read()
             )
  end

  test "token checkout locks the active mailbox before the shared authorization", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    queries =
      repo_queries_during(fn ->
        assert {:ok, "access-secret"} =
                 OAuthAuthorizations.checkout_access_token(
                   receive.oauth_authorization_id,
                   FakeMicrosoft,
                   [],
                   required_scope: MicrosoftScopes.read(),
                   now: @now
                 )
      end)

    mailbox_lock =
      Enum.find_index(queries, fn query ->
        String.contains?(query, ~s(FROM "mailboxes")) and
          String.contains?(query, "FOR UPDATE")
      end)

    authorization_lock =
      Enum.find_index(queries, fn query ->
        String.contains?(query, ~s(FROM "connector_oauth_authorizations")) and
          String.contains?(query, "FOR UPDATE")
      end)

    assert is_integer(mailbox_lock)
    assert is_integer(authorization_lock)
    assert mailbox_lock < authorization_lock
  end

  test "OAuth setup returns connect without exposing account state", %{
    account: account,
    address: address
  } do
    for provider <- ["gmail", "microsoft"], purpose <- [:receive, :send] do
      assert {:ok, setup} = Connectors.oauth_method_setup(account.id, provider, purpose)
      assert_setup(setup, provider, purpose, :connect, [account.id, address])
    end

    assert {:error, %{class: :permanent}} =
             Connectors.oauth_method_setup("not-a-uuid", "microsoft", :send)

    assert {:error, %{class: :permanent}} =
             Connectors.oauth_method_setup(account.id, "unsupported", :send)

    assert {:error, %{class: :permanent}} =
             Connectors.oauth_method_setup(account.id, "microsoft", :unsupported)
  end

  test "OAuth setup distinguishes upgrade add connected and reconnect without leaking state", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    assert {:ok, receive_setup} =
             Connectors.oauth_method_setup(account.id, "microsoft", :receive)

    assert_setup(receive_setup, "microsoft", :receive, :connected, [
      authorization.id,
      receive.id,
      address,
      MicrosoftScopes.read(),
      "access-secret",
      "refresh-secret"
    ])

    assert {:ok, send_upgrade} =
             Connectors.oauth_method_setup(account.id, "microsoft", :send)

    assert_setup(send_upgrade, "microsoft", :send, :upgrade, [
      authorization.id,
      receive.id,
      address,
      MicrosoftScopes.read()
    ])

    add_send_account = create_account!(account, "add-send")
    add_send_address = Accounts.account_address(add_send_account)

    assert {:ok, add_send_receive} =
             complete(:receive, add_send_account, add_send_address,
               subject: "add-send-subject",
               required_scopes: all_scopes(),
               scopes: access_token_scopes(all_scopes())
             )

    add_send_authorization =
      Repo.get!(OAuthAuthorization, add_send_receive.oauth_authorization_id)

    assert {:ok, send_add} =
             Connectors.oauth_method_setup(add_send_account.id, "microsoft", :send)

    assert_setup(send_add, "microsoft", :send, :add, [
      add_send_authorization.id,
      add_send_receive.id,
      add_send_address,
      MicrosoftScopes.send()
    ])

    assert {:ok, %SendMethod{} = added_send} =
             Connectors.add_authorized_oauth_method(
               add_send_account.id,
               "microsoft",
               :send
             )

    assert {:ok, added_send_setup} =
             Connectors.oauth_method_setup(add_send_account.id, "microsoft", :send)

    assert_setup(added_send_setup, "microsoft", :send, :connected, [
      add_send_authorization.id,
      added_send.id,
      add_send_address
    ])

    add_receive_account = create_account!(account, "add-receive")
    add_receive_address = Accounts.account_address(add_receive_account)

    assert {:ok, add_receive_send} =
             complete(:send, add_receive_account, add_receive_address,
               subject: "add-receive-subject",
               required_scopes: all_scopes(),
               scopes: access_token_scopes(all_scopes()),
               expires_at: ~U[2099-01-01 00:00:00.000000Z]
             )

    add_receive_authorization =
      Repo.get!(OAuthAuthorization, add_receive_send.oauth_authorization_id)

    assert {:ok, receive_add} =
             Connectors.oauth_method_setup(add_receive_account.id, "microsoft", :receive)

    assert_setup(receive_add, "microsoft", :receive, :add, [
      add_receive_authorization.id,
      add_receive_send.id,
      add_receive_address,
      MicrosoftScopes.read()
    ])

    assert {:ok, %ReceiveMethod{} = added_receive} =
             Connectors.add_authorized_oauth_method(
               add_receive_account.id,
               "microsoft",
               :receive
             )

    assert {:ok, added_receive_setup} =
             Connectors.oauth_method_setup(add_receive_account.id, "microsoft", :receive)

    assert_setup(added_receive_setup, "microsoft", :receive, :connected, [
      add_receive_authorization.id,
      added_receive.id,
      add_receive_address
    ])

    reconnect_error = %ProviderError{
      class: :reconnect,
      code: :invalid_grant,
      message: "provider-error-body-secret"
    }

    assert {:ok, _authorization} =
             Connectors.mark_oauth_reconnect_required(authorization.id, reconnect_error)

    for purpose <- [:receive, :send] do
      assert {:ok, reconnect_setup} =
               Connectors.oauth_method_setup(account.id, "microsoft", purpose)

      assert_setup(reconnect_setup, "microsoft", purpose, :reconnect, [
        authorization.id,
        receive.id,
        address,
        MicrosoftScopes.read(),
        "access-secret",
        "refresh-secret",
        "provider-error-body-secret"
      ])
    end
  end

  test "OAuth setup does not report a misbound receive method as connected", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)

    from(method in ReceiveMethod, where: method.id == ^receive.id)
    |> Repo.update_all(set: [provider_account_id: "different-microsoft-subject"])

    assert {:ok, %OAuthMethodSetup{state: :add}} =
             Connectors.oauth_method_setup(account.id, "microsoft", :receive)
  end

  test "OAuth setup does not report a method with the wrong sender as connected", %{
    account: account,
    address: address
  } do
    assert {:ok, send_method} = complete(:send, account, address)

    from(method in SendMethod, where: method.id == ^send_method.id)
    |> Repo.update_all(set: [email_address: "different@example.test"])

    assert {:ok, %OAuthMethodSetup{state: :add}} =
             Connectors.oauth_method_setup(account.id, "microsoft", :send)
  end

  test "public method addition normalizes provider errors", %{
    account: account,
    address: address
  } do
    assert {:ok, _send_method} =
             complete(:send, account, address,
               required_scopes: all_scopes(),
               scopes: access_token_scopes(all_scopes()),
               expires_at: ~U[2099-01-01 00:00:00.000000Z]
             )

    Application.put_env(:manifold_connectors, :adapters, microsoft: FailingMicrosoft)

    assert {:error,
            %Manifold.Core.Error{
              class: :temporary,
              reason: :provider_unavailable,
              message: "Microsoft Graph is temporarily unavailable",
              details: %{
                provider_class: :temporary,
                retry_after_seconds: 30
              }
            }} =
             Connectors.add_authorized_oauth_method(account.id, "microsoft", :receive)
  end

  test "Microsoft token exchange honors the snapshotted scope union when scope is omitted" do
    requested_scopes =
      Enum.sort([
        "openid",
        "User.Read",
        MicrosoftScopes.offline(),
        MicrosoftScopes.send(),
        MicrosoftScopes.read()
      ])

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      form = Plug.Conn.Query.decode(body)

      assert form["scope"] == Enum.join(requested_scopes, " ")

      Req.Test.json(conn, %{
        "access_token" => "snapshotted-union-access-token",
        "refresh_token" => "snapshotted-union-refresh-token",
        "expires_in" => 3_600
      })
    end)

    config = [
      client_id: "scope-union-client",
      client_secret: "scope-union-secret",
      token_url: "https://login.microsoft.test/organizations/oauth2/v2.0/token",
      scopes: MicrosoftScopes.read(),
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

    assert {:ok, %Token{scopes: ^requested_scopes}} =
             MicrosoftGraph.exchange_code(
               "authorization-code-secret",
               "pkce-verifier-secret",
               "https://mail.example.test/connectors/microsoft/callback",
               config,
               now: @now,
               required_scopes: requested_scopes
             )
  end

  test "Microsoft token exchange preserves configured fallback scope order" do
    configured_scopes = "openid profile offline_access User.Read Mail.Read"

    Req.Test.expect(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      form = Plug.Conn.Query.decode(body)

      assert form["scope"] == configured_scopes

      Req.Test.json(conn, %{
        "access_token" => "legacy-fallback-access-token",
        "refresh_token" => "legacy-fallback-refresh-token",
        "expires_in" => 3_600
      })
    end)

    config = [
      client_id: "legacy-fallback-client",
      client_secret: "legacy-fallback-secret",
      token_url: "https://login.microsoft.test/organizations/oauth2/v2.0/token",
      scopes: configured_scopes,
      req_options: [plug: {Req.Test, __MODULE__}]
    ]

    assert {:ok, %Token{scopes: scopes}} =
             MicrosoftGraph.exchange_code(
               "legacy-authorization-code",
               "legacy-pkce-verifier",
               "https://mail.example.test/connectors/microsoft/callback",
               config,
               now: @now
             )

    assert scopes == String.split(configured_scopes)
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

  test "a stale phase-one generation is rejected before refresh provider I/O", %{
    account: account,
    address: address
  } do
    assert {:ok, receive} = complete(:receive, account, address)
    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)

    advanced =
      authorization
      |> OAuthAuthorization.changeset(%{})
      |> Ecto.Changeset.force_change(:status, authorization.status)
      |> Repo.update!()

    {:ok, refresh_count} = Agent.start_link(fn -> 0 end)

    refreshed = %Token{
      access_token: "unexpected-refreshed-access",
      refresh_token: nil,
      expires_at: ~U[2026-08-12 04:00:00.000000Z],
      scopes: [MicrosoftScopes.read()]
    }

    assert {:error, %{class: :permanent, reason: :stale_oauth_authorization}} =
             OAuthAuthorizations.checkout_access_token(
               authorization.id,
               FakeMicrosoft,
               [],
               required_scope: MicrosoftScopes.read(),
               expected_authorization_lock_version: authorization.lock_version,
               now: @refresh_now,
               provider_opts: [
                 refresh_count: refresh_count,
                 refresh_result: {:ok, refreshed},
                 test_pid: self()
               ]
             )

    assert Agent.get(refresh_count, & &1) == 0
    refute_receive {:refresh_started, _, _, _}, 100

    assert authorization_snapshot(Repo.get!(OAuthAuthorization, authorization.id)) ==
             authorization_snapshot(advanced)
  end

  test "disconnecting Microsoft receive leaves send connected and vice versa", %{
    account: account,
    address: address
  } do
    {receive, send_method, authorization} = complete_both(account, address)

    assert {:ok, disconnected_receive} =
             Connectors.disconnect(receive.id)

    assert disconnected_receive.status == "disconnected"

    persisted_send = Repo.get!(SendMethod, send_method.id)
    assert persisted_send.status == "connected"
    assert persisted_send.oauth_authorization_id == authorization.id

    persisted_authorization = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted_authorization.status == "connected"
    assert persisted_authorization.lock_version > authorization.lock_version

    assert persisted_authorization.access_token_ciphertext ==
             authorization.access_token_ciphertext

    assert persisted_authorization.refresh_token_ciphertext ==
             authorization.refresh_token_ciphertext

    send_first_account = create_account!(account, "disconnect-send-first")
    send_first_address = Accounts.account_address(send_first_account)

    {send_first_receive, send_first_method, send_first_authorization} =
      complete_both(send_first_account, send_first_address,
        subject: "disconnect-send-first-subject"
      )

    assert {:ok, disconnected_send} =
             Connectors.disconnect_send_method(send_first_account.id, send_first_method.id)

    assert disconnected_send.status == "disconnected"

    persisted_receive = Repo.get!(ReceiveMethod, send_first_receive.id)
    assert persisted_receive.status == "connected"
    assert persisted_receive.oauth_authorization_id == send_first_authorization.id

    persisted_send_first_authorization =
      Repo.get!(OAuthAuthorization, send_first_authorization.id)

    assert persisted_send_first_authorization.status == "connected"

    assert persisted_send_first_authorization.lock_version >
             send_first_authorization.lock_version

    assert persisted_send_first_authorization.access_token_ciphertext ==
             send_first_authorization.access_token_ciphertext

    assert persisted_send_first_authorization.refresh_token_ciphertext ==
             send_first_authorization.refresh_token_ciphertext
  end

  test "repeated send disconnect advances method and authorization generations", %{
    account: account,
    address: address
  } do
    {receive, send_method, authorization} = complete_both(account, address)

    assert {:ok, %SendMethod{status: "disconnected"}} =
             OAuthAuthorizations.disconnect_method(:send, account.id, send_method.id)

    disconnected_send = Repo.get!(SendMethod, send_method.id)
    generation = Repo.get!(OAuthAuthorization, authorization.id)
    events_before = Repo.aggregate(ConnectorEvent, :count)

    assert {:ok, %SendMethod{status: "disconnected"} = repeated} =
             OAuthAuthorizations.disconnect_method(:send, account.id, send_method.id)

    advanced = Repo.get!(OAuthAuthorization, authorization.id)

    assert repeated.lock_version > disconnected_send.lock_version
    assert advanced.lock_version > generation.lock_version
    assert advanced.status == "connected"
    assert advanced.access_token_ciphertext == authorization.access_token_ciphertext
    assert advanced.refresh_token_ciphertext == authorization.refresh_token_ciphertext
    assert Repo.get!(ReceiveMethod, receive.id).status == "connected"
    assert Repo.aggregate(ConnectorEvent, :count) == events_before + 1
  end

  test "the final Microsoft disconnect erases both token ciphertext fields", %{
    account: account,
    address: address
  } do
    {receive, send_method, authorization} = complete_both(account, address)

    assert {:ok, %ReceiveMethod{status: "disconnected"}} =
             Connectors.disconnect(receive.id)

    assert {:ok, %SendMethod{status: "disconnected"}} =
             Connectors.disconnect_send_method(account.id, send_method.id)

    disconnected = Repo.get!(OAuthAuthorization, authorization.id)
    assert disconnected.status == "disconnected"
    assert disconnected.provider_subject_id == @subject
    assert disconnected.email_address == address
    assert is_nil(disconnected.access_token_ciphertext)
    assert is_nil(disconnected.refresh_token_ciphertext)
    assert is_nil(disconnected.token_expires_at)
  end

  test "deleting Microsoft receive through the public API advances shared lifecycle", %{
    account: account,
    address: address
  } do
    {receive, send_method, authorization} = complete_both(account, address)

    assert {:ok, %ReceiveMethod{id: receive_id}} =
             Connectors.delete_receive_method(receive.id)

    assert receive_id == receive.id
    refute Repo.get(ReceiveMethod, receive.id)
    assert Repo.get!(SendMethod, send_method.id).status == "connected"

    persisted_authorization = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted_authorization.status == "connected"
    assert persisted_authorization.lock_version > authorization.lock_version

    assert persisted_authorization.access_token_ciphertext ==
             authorization.access_token_ciphertext

    assert persisted_authorization.refresh_token_ciphertext ==
             authorization.refresh_token_ciphertext
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

  test "successful Microsoft reconnect invalidates mapping metadata without replacing cursors", %{
    account: account,
    address: address
  } do
    {receive, _send_method, authorization} = complete_both(account, address)

    [initial_cursor] =
      Repo.all(from(cursor in SyncCursor, where: cursor.external_account_id == ^receive.id))

    folders =
      initial_cursor
      |> SyncCursor.changeset(%{
        scope: "folders",
        phase: "incremental",
        committed_cursor: "https://graph.microsoft.test/folders/committed-delta",
        metadata: %{
          "folder_mapping_version" => 1,
          "folder_kinds_by_id" => %{"folder-inbox" => "inbox"},
          "fixture_marker" => "retain"
        },
        last_completed_at: @now
      })
      |> Repo.update!()

    selected =
      %SyncCursor{}
      |> SyncCursor.changeset(%{
        external_account_id: receive.id,
        scope: "folder:folder-inbox",
        phase: "incremental",
        committed_cursor: "https://graph.microsoft.test/messages/inbox-committed-delta",
        metadata: %{
          "folder_mapping_version" => 1,
          "folder_kind" => "inbox",
          "fixture_marker" => "retain"
        },
        generation: 7,
        last_completed_at: @now
      })
      |> Repo.insert!()

    positions_before = reconnect_cursor_positions(receive.id)

    assert {:ok, _authorization} =
             Connectors.mark_oauth_reconnect_required(
               authorization.id,
               %ProviderError{
                 class: :reconnect,
                 code: :invalid_grant,
                 message: "provider reconnect required"
               }
             )

    assert {:ok, %ReceiveMethod{id: receive_id, status: "connected"}} =
             complete(:receive, account, address,
               access_token: "reconnected-access",
               refresh_token: nil,
               required_scopes: all_scopes(),
               scopes: access_token_scopes(all_scopes()),
               provider_opts: [test_pid: self()]
             )

    assert receive_id == receive.id
    assert_receive {:exchange_required_scopes, required_scopes}
    assert required_scopes == all_scopes()
    refute_receive :initial_cursors, 100
    assert reconnect_cursor_positions(receive.id) == positions_before

    refreshed_folders = Repo.get!(SyncCursor, folders.id)
    refreshed_selected = Repo.get!(SyncCursor, selected.id)

    assert refreshed_folders.metadata == %{
             "folder_kinds_by_id" => %{"folder-inbox" => "inbox"},
             "folder_mapping_refresh_required" => true,
             "fixture_marker" => "retain"
           }

    assert refreshed_selected.metadata == %{
             "folder_kind" => "inbox",
             "folder_mapping_refresh_required" => true,
             "fixture_marker" => "retain"
           }
  end

  test "successful Microsoft send reconnect invalidates the restored receive mapping", %{
    account: account,
    address: address
  } do
    {receive, _send_method, authorization} = complete_both(account, address)

    cursor =
      SyncCursor
      |> Repo.get_by!(external_account_id: receive.id)
      |> SyncCursor.changeset(%{
        scope: "folders",
        phase: "incremental",
        committed_cursor: "https://graph.microsoft.test/folders/committed-delta",
        metadata: %{
          "folder_mapping_version" => 1,
          "folder_kinds_by_id" => %{"folder-sent" => "sent"}
        },
        last_completed_at: @now
      })
      |> Repo.update!()

    positions_before = reconnect_cursor_positions(receive.id)
    jobs_before = sync_job_count(receive.id)

    assert {:ok, _authorization} =
             Connectors.mark_oauth_reconnect_required(
               authorization.id,
               %ProviderError{
                 class: :reconnect,
                 code: :invalid_grant,
                 message: "provider reconnect required"
               }
             )

    assert {:ok, %SendMethod{status: "connected"}} =
             complete(:send, account, address,
               access_token: "reconnected-send-access",
               refresh_token: nil,
               required_scopes: all_scopes(),
               scopes: access_token_scopes(all_scopes())
             )

    assert Repo.get!(ReceiveMethod, receive.id).status == "connected"
    assert reconnect_cursor_positions(receive.id) == positions_before
    assert sync_job_count(receive.id) == jobs_before

    assert Repo.get!(SyncCursor, cursor.id).metadata == %{
             "folder_kinds_by_id" => %{"folder-sent" => "sent"},
             "folder_mapping_refresh_required" => true
           }
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

  test "receive setup carries its own refresh generation into final persistence", %{
    account: account,
    address: address
  } do
    assert {:ok, send_method} =
             complete(:send, account, address, scopes: access_token_scopes(all_scopes()))

    authorization = Repo.get!(OAuthAuthorization, send_method.oauth_authorization_id)

    refreshed = %Token{
      access_token: "setup-refreshed-access",
      refresh_token: nil,
      expires_at: ~U[2026-08-12 04:00:00.000000Z],
      scopes: access_token_scopes(all_scopes())
    }

    assert {:ok, %ReceiveMethod{status: "connected"} = receive} =
             OAuthAuthorizations.add_authorized_method(
               "microsoft",
               account.id,
               :receive,
               FakeMicrosoft,
               [],
               now: @refresh_now,
               provider_opts: [refresh_result: {:ok, refreshed}]
             )

    advanced = Repo.get!(OAuthAuthorization, authorization.id)
    assert advanced.lock_version > authorization.lock_version

    assert {:ok, "setup-refreshed-access"} =
             Crypto.decrypt(
               advanced.access_token_ciphertext,
               "credential:#{authorization.id}:access"
             )

    assert sync_cursor_ids(receive.id) != []
    assert sync_job_count(receive.id) == 1
  end

  test "phase-one receive setup cannot absorb an absent-create-delete ABA", %{
    account: account,
    address: address
  } do
    assert {:ok, send_method} =
             complete(:send, account, address, scopes: access_token_scopes(all_scopes()))

    authorization = Repo.get!(OAuthAuthorization, send_method.oauth_authorization_id)
    events_before = Repo.aggregate(ConnectorEvent, :count)
    gate = make_ref()
    test_pid = self()
    {:ok, refresh_count} = Agent.start_link(fn -> 0 end)

    refreshed = %Token{
      access_token: "unexpected-aba-refresh",
      refresh_token: nil,
      expires_at: ~U[2026-08-12 04:00:00.000000Z],
      scopes: access_token_scopes(all_scopes())
    }

    add_task =
      Task.async(fn ->
        OAuthAuthorizations.add_authorized_method(
          "microsoft",
          account.id,
          :receive,
          FakeMicrosoft,
          [],
          now: @refresh_now,
          after_authorized_method_snapshot: fn ->
            send(test_pid, {:authorized_method_snapshotted, self()})

            receive do
              {:release_authorized_method_snapshot, ^gate} -> :ok
            end
          end,
          provider_opts: [
            refresh_count: refresh_count,
            refresh_result: {:ok, refreshed},
            test_pid: test_pid
          ]
        )
      end)

    assert_receive {:authorized_method_snapshotted, snapshot_process}

    assert {:ok, %ReceiveMethod{} = transient_receive} =
             OAuthAuthorizations.add_authorized_method(
               "microsoft",
               account.id,
               :receive,
               FakeMicrosoft,
               [],
               now: @now
             )

    assert {:ok, %ReceiveMethod{id: transient_id}} =
             OAuthAuthorizations.delete_receive_method(transient_receive.id)

    assert transient_id == transient_receive.id
    send(snapshot_process, {:release_authorized_method_snapshot, gate})

    assert {:error, %{class: :permanent, reason: :stale_oauth_authorization}} =
             Task.await(add_task, 5_000)

    assert Agent.get(refresh_count, & &1) == 0
    refute_receive {:refresh_started, _, _, _}, 100
    refute_receive :initial_cursors, 100

    advanced = Repo.get!(OAuthAuthorization, authorization.id)
    assert advanced.lock_version > authorization.lock_version
    assert advanced.status == "connected"
    assert advanced.access_token_ciphertext == authorization.access_token_ciphertext
    assert advanced.refresh_token_ciphertext == authorization.refresh_token_ciphertext
    assert Repo.get!(SendMethod, send_method.id).status == "connected"
    assert Repo.aggregate(ReceiveMethod, :count) == 0
    assert Repo.aggregate(SyncCursor, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
    assert Repo.aggregate(ConnectorEvent, :count) == events_before + 2
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

  test "blocked receive add cannot undo a repeated disconnected receive lifecycle", %{
    account: account,
    address: address
  } do
    {receive, send_method, authorization} = complete_both(account, address)

    assert {:ok, %ReceiveMethod{status: "disconnected"}} =
             OAuthAuthorizations.disconnect_method(:receive, account.id, receive.id)

    disconnected_receive = Repo.get!(ReceiveMethod, receive.id)
    generation = Repo.get!(OAuthAuthorization, authorization.id)
    cursor_ids_before = sync_cursor_ids(receive.id)
    jobs_before = sync_job_count(receive.id)
    events_before = Repo.aggregate(ConnectorEvent, :count)
    gate = make_ref()

    {add_task, cursor_process} = start_blocked_receive_add(account, gate)

    assert {:ok, %ReceiveMethod{status: "disconnected"} = repeated} =
             OAuthAuthorizations.disconnect_method(:receive, account.id, receive.id)

    advanced = Repo.get!(OAuthAuthorization, authorization.id)
    assert repeated.lock_version > disconnected_receive.lock_version
    assert advanced.lock_version > generation.lock_version

    send(cursor_process, {:release_cursors, gate})

    assert {:error, %{class: :permanent, reason: :stale_oauth_authorization}} =
             Task.await(add_task, 5_000)

    assert Repo.get!(ReceiveMethod, receive.id).status == "disconnected"
    assert Repo.get!(SendMethod, send_method.id).status == "connected"
    assert advanced.status == "connected"
    assert advanced.access_token_ciphertext == authorization.access_token_ciphertext
    assert advanced.refresh_token_ciphertext == authorization.refresh_token_ciphertext
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

  defp create_account!(account, prefix) do
    local_part = "#{prefix}-#{System.unique_integer([:positive])}"
    {:ok, created} = Accounts.create_account(account.domain, %{local_part: local_part})
    Repo.preload(created, :domain)
  end

  defp attach_oauth_telemetry(events) do
    handler_id = "microsoft-oauth-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, pid ->
          send(pid, {:oauth_telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp assert_oauth_telemetry(operation, outcome) do
    event = [:manifold, :connectors, :oauth, operation, :stop]

    assert_receive {:oauth_telemetry, ^event,
                    %{duration_ms: duration_ms, attempt_count: 1} = measurements,
                    %{outcome: ^outcome} = metadata}

    assert is_integer(duration_ms) and duration_ms >= 0
    assert Map.keys(measurements) |> Enum.sort() == [:attempt_count, :duration_ms]

    %{measurements: measurements, metadata: metadata}
  end

  defp assert_setup(setup, provider, purpose, state, secrets) do
    assert setup.__struct__ == OAuthMethodSetup

    assert Map.from_struct(setup) == %{
             provider: provider,
             purpose: purpose,
             state: state
           }

    inspected = inspect(setup)
    Enum.each(secrets, fn secret -> refute inspected =~ secret end)
  end

  defp complete_both(account, address, opts \\ []) do
    assert {:ok, receive} = complete(:receive, account, address, opts)

    assert {:ok, send_method} =
             complete(
               :send,
               account,
               address,
               opts
               |> Keyword.put(:required_scopes, all_scopes())
               |> Keyword.put(:scopes, access_token_scopes(all_scopes()))
               |> Keyword.put(:refresh_token, nil)
             )

    authorization = Repo.get!(OAuthAuthorization, receive.oauth_authorization_id)
    {receive, send_method, authorization}
  end

  defp complete(purpose, account, address, opts \\ []) do
    required_scopes = Keyword.get(opts, :required_scopes, purpose_scopes(purpose))
    setting = Repo.get_by!(OAuthProviderSetting, provider: "microsoft")

    consumed = %Consumed{
      provider: "microsoft",
      mailbox_id: account.id,
      purpose: purpose,
      required_scopes: required_scopes,
      redirect_uri: "https://mail.example.test/connectors/microsoft/callback",
      pkce_verifier: "verifier-secret",
      oauth_provider_setting_id: setting.id,
      oauth_provider_setting_lock_version: setting.lock_version
    }

    token = %Token{
      access_token: Keyword.get(opts, :access_token, "access-secret"),
      refresh_token: Keyword.get(opts, :refresh_token, "refresh-secret"),
      expires_at: Keyword.get(opts, :expires_at, @expires_at),
      scopes: Keyword.get(opts, :scopes, access_token_scopes(required_scopes))
    }

    identity =
      Keyword.get(opts, :identity, %Identity{
        id: Keyword.get(opts, :subject, @subject),
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

  defp start_and_consume_microsoft!(account_id, purpose) do
    redirect_uri = "https://mail.example.test/connectors/microsoft/callback"

    assert {:ok, authorization} =
             OAuth.start("microsoft", account_id, redirect_uri, purpose: purpose)

    assert {:ok, consumed} =
             OAuth.consume("microsoft", authorization.state, redirect_uri)

    consumed
  end

  defp completion_provider_opts(address, purpose, extra) do
    required_scopes = purpose_scopes(purpose)

    token = %Token{
      access_token: "access-secret",
      refresh_token: "refresh-secret",
      expires_at: @expires_at,
      scopes: access_token_scopes(required_scopes)
    }

    Keyword.merge(
      [
        token: {:ok, token},
        identity: {:ok, %Identity{id: @subject, email_address: address}}
      ],
      extra
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

  defp reconnect_cursor_positions(receive_method_id) do
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

defmodule Manifold.Connectors.MicrosoftAuthorizationCursorFenceTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Manifold.Accounts
  alias Manifold.Connectors.{Crypto, MicrosoftScopes, OAuthAuthorizations}

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    OAuthAuthorization,
    ReceiveMethod,
    SendMethod,
    SyncCursor
  }

  alias Manifold.Connectors.MicrosoftAuthorizationsTest.FakeMicrosoft
  alias Manifold.Repo

  @now ~U[2026-08-12 01:00:00.000000Z]
  @expires_at ~U[2026-08-12 02:00:00.000000Z]

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    old_key = Application.get_env(:manifold_connectors, :encryption_key)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    on_exit(fn ->
      if old_key do
        Application.put_env(:manifold_connectors, :encryption_key, old_key)
      else
        Application.delete_env(:manifold_connectors, :encryption_key)
      end
    end)

    :ok
  end

  for operation <- [:setup, :delete] do
    test "#{operation} cursor fence fails fast and releases an earlier partial cursor lock" do
      operation = unquote(operation)
      fixture = insert_lifecycle_fixture!(operation)
      supervisor = start_supervised!(Task.Supervisor)
      test_pid = self()
      gate = make_ref()

      holder =
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            Repo.transaction(fn ->
              assert %SyncCursor{} =
                       SyncCursor
                       |> where([cursor], cursor.id == ^fixture.later_cursor_id)
                       |> lock("FOR UPDATE")
                       |> Repo.one!()

              send(test_pid, {:later_cursor_locked, self(), gate})

              receive do
                {:delete_earlier_cursor, ^gate} -> :ok
              end

              assert {1, nil} =
                       SyncCursor
                       |> where([cursor], cursor.id == ^fixture.earlier_cursor_id)
                       |> Repo.delete_all()

              send(test_pid, {:earlier_cursor_deleted, self(), gate})

              receive do
                {:commit_cursor_checkpoint, ^gate} -> :ok
              end
            end)
          end)
        end)

      try do
        assert_receive {:later_cursor_locked, holder_pid, ^gate}, 5_000

        lifecycle =
          Task.Supervisor.async_nolink(supervisor, fn ->
            Sandbox.unboxed_run(Repo, fn -> run_lifecycle(operation, fixture) end)
          end)

        try do
          assert {:ok, {:error, %{class: :temporary, reason: :oauth_lifecycle_busy}}} =
                   Task.yield(lifecycle, 1_000)

          send(holder_pid, {:delete_earlier_cursor, gate})
          assert_receive {:earlier_cursor_deleted, ^holder_pid, ^gate}, 1_000
          send(holder_pid, {:commit_cursor_checkpoint, gate})
          assert {:ok, :ok} = Task.await(holder, 5_000)

          assert lifecycle_snapshot(fixture) == fixture.lifecycle_snapshot
          assert cursor_ids(fixture.receive.id) == [fixture.later_cursor_id]
          assert Repo.get!(SendMethod, fixture.send_method.id).status == "connected"
          assert scoped_job_count(fixture.receive.id) == 0
          assert scoped_event_count(fixture.authorization.id) == 0
        after
          stop_task(lifecycle)
        end
      after
        stop_task(holder)
        cleanup_fixture!(fixture)
      end
    end
  end

  defp insert_lifecycle_fixture!(operation) do
    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "microsoft-fence-#{suffix}.test"})
    {:ok, account} = Accounts.create_account(domain, %{local_part: "person"})
    account = Repo.preload(account, :domain)
    address = Accounts.account_address(account)
    authorization_id = Ecto.UUID.generate()
    subject = "microsoft-cursor-fence-#{suffix}"
    scopes = all_scopes()
    cursor_id_prefix = Ecto.UUID.generate() |> String.slice(0, 35)
    earlier_cursor_id = cursor_id_prefix <> "1"
    later_cursor_id = cursor_id_prefix <> "2"

    assert {:ok, access_token_ciphertext} =
             Crypto.encrypt(
               "cursor-fence-access",
               "credential:#{authorization_id}:access"
             )

    assert {:ok, refresh_token_ciphertext} =
             Crypto.encrypt(
               "cursor-fence-refresh",
               "credential:#{authorization_id}:refresh"
             )

    authorization =
      %OAuthAuthorization{id: authorization_id}
      |> OAuthAuthorization.changeset(%{
        account_id: account.id,
        provider: "microsoft",
        provider_subject_id: subject,
        email_address: address,
        granted_scopes: scopes,
        status: "connected",
        access_token_ciphertext: access_token_ciphertext,
        refresh_token_ciphertext: refresh_token_ciphertext,
        token_expires_at: @expires_at
      })
      |> Repo.insert!()

    receive_status = if operation == :setup, do: "failed", else: "connected"
    receive_enabled = operation == :delete

    receive =
      %ReceiveMethod{}
      |> ReceiveMethod.changeset(%{
        account_id: account.id,
        oauth_authorization_id: authorization.id,
        kind: "microsoft",
        provider_account_id: subject,
        email_address: address,
        status: receive_status,
        enabled: receive_enabled,
        sync_enabled: receive_enabled,
        granted_scopes: scopes
      })
      |> Repo.insert!()

    send_method =
      %SendMethod{}
      |> SendMethod.changeset(%{
        account_id: account.id,
        oauth_authorization_id: authorization.id,
        kind: "microsoft",
        email_address: address,
        status: "connected",
        enabled: true
      })
      |> Repo.insert!()

    insert_cursor!(receive.id, earlier_cursor_id, "earlier")
    insert_cursor!(receive.id, later_cursor_id, "later")

    fixture = %{
      domain: domain,
      account: account,
      authorization: authorization,
      receive: receive,
      send_method: send_method,
      earlier_cursor_id: earlier_cursor_id,
      later_cursor_id: later_cursor_id
    }

    Map.put(fixture, :lifecycle_snapshot, lifecycle_snapshot(fixture))
  end

  defp insert_cursor!(receive_method_id, id, scope) do
    %SyncCursor{id: id}
    |> SyncCursor.changeset(%{
      external_account_id: receive_method_id,
      scope: scope,
      phase: "initial",
      metadata: %{},
      generation: 1
    })
    |> Repo.insert!()
  end

  defp run_lifecycle(:setup, fixture) do
    OAuthAuthorizations.add_authorized_method(
      "microsoft",
      fixture.account.id,
      :receive,
      FakeMicrosoft,
      [],
      now: @now
    )
  end

  defp run_lifecycle(:delete, fixture) do
    OAuthAuthorizations.delete_receive_method(fixture.receive.id)
  end

  defp lifecycle_snapshot(fixture) do
    %{
      authorization:
        fixture.authorization.id
        |> then(&Repo.get!(OAuthAuthorization, &1))
        |> Map.take([
          :status,
          :access_token_ciphertext,
          :refresh_token_ciphertext,
          :token_expires_at,
          :lock_version
        ]),
      receive:
        fixture.receive.id
        |> then(&Repo.get!(ReceiveMethod, &1))
        |> Map.take([:status, :enabled, :sync_enabled, :lock_version])
    }
  end

  defp cursor_ids(receive_method_id) do
    SyncCursor
    |> where([cursor], cursor.external_account_id == ^receive_method_id)
    |> order_by([cursor], asc: cursor.id)
    |> select([cursor], cursor.id)
    |> Repo.all()
  end

  defp scoped_job_count(receive_method_id) do
    Repo.aggregate(
      from(job in Oban.Job,
        where: fragment("?->>'external_account_id' = ?", job.args, ^receive_method_id)
      ),
      :count
    )
  end

  defp scoped_event_count(authorization_id) do
    Repo.aggregate(
      from(event in ConnectorEvent,
        where: event.oauth_authorization_id == ^authorization_id
      ),
      :count
    )
  end

  defp cleanup_fixture!(fixture) do
    Oban.Job
    |> where(
      [job],
      fragment("?->>'external_account_id' = ?", job.args, ^fixture.receive.id)
    )
    |> Repo.delete_all()

    SyncCursor
    |> where([cursor], cursor.external_account_id == ^fixture.receive.id)
    |> Repo.delete_all()

    ReceiveMethod
    |> where([method], method.account_id == ^fixture.account.id)
    |> Repo.delete_all()

    SendMethod
    |> where([method], method.account_id == ^fixture.account.id)
    |> Repo.delete_all()

    OAuthAuthorization
    |> where([authorization], authorization.account_id == ^fixture.account.id)
    |> Repo.delete_all()

    cleanup_account_and_domain!(fixture)
  end

  defp cleanup_account_and_domain!(fixture) do
    fixture.account
    |> then(&Repo.get!(fixture.account.__struct__, &1.id))
    |> Repo.delete!()

    fixture.domain
    |> then(&Repo.get!(fixture.domain.__struct__, &1.id))
    |> Repo.delete!()
  end

  defp all_scopes do
    Enum.sort([MicrosoftScopes.read(), MicrosoftScopes.send(), MicrosoftScopes.offline()])
  end

  defp stop_task(%Task{} = task) do
    if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill), else: :ok
  end
end

defmodule ManifoldWeb.ExternalAccountsWebTest do
  use ManifoldWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.{Crypto, MicrosoftScopes}
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Connectors.Provider.{Identity, Page, RawMessage, Token}
  alias Manifold.Connectors.Provider.SyncCursor, as: ProviderCursor
  alias Manifold.Connectors.Schema.{OAuthAuthorization, OAuthTransaction}
  alias Manifold.Repo

  defmodule GmailProvider do
    @behaviour Manifold.Connectors.Provider

    @impl true
    def exchange_code("valid-code", _verifier, _redirect_uri, _config, opts) do
      {:ok,
       %Token{
         access_token: "gmail-access-token",
         refresh_token: "gmail-refresh-token",
         expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
         scopes: Enum.uniq(["openid", "email"] ++ Keyword.fetch!(opts, :required_scopes))
       }}
    end

    def exchange_code("pre-cutover-code", _verifier, _redirect_uri, _config, _opts) do
      send(
        Application.fetch_env!(:manifold_connectors, :oauth_exchange_probe),
        :pre_cutover_exchange_called
      )

      raise "pre-cutover Gmail transaction reached provider exchange"
    end

    @impl true
    def refresh_token(_refresh_token, _config, _opts), do: raise("not used")

    @impl true
    def identity("gmail-access-token", _config, _opts) do
      {:ok, %Identity{id: "gmail-account-1", email_address: "person@gmail.example"}}
    end

    @impl true
    def initial_cursors("gmail-access-token", _config, _opts) do
      {:ok, [%ProviderCursor{scope: "mailbox", phase: "bootstrap"}]}
    end

    @impl true
    def sync_page(_access_token, cursor, _config, _opts),
      do: {:ok, %Page{cursor: cursor}}

    @impl true
    def fetch_raw(_access_token, _message_id, _config, _opts),
      do: {:ok, %RawMessage{bytes: "Subject: test\r\n\r\nBody\r\n"}}
  end

  defmodule MicrosoftProvider do
    @behaviour Manifold.Connectors.Provider

    alias Manifold.Connectors.MicrosoftScopes
    alias Manifold.Connectors.Provider.{Error, Identity, Page, RawMessage, Token}
    alias Manifold.Connectors.Provider.SyncCursor

    @impl true
    def exchange_code("provider-failure-code", _verifier, _redirect_uri, _config, _opts) do
      {:error,
       %Error{
         class: :temporary,
         code: :provider_unavailable,
         message: "raw-microsoft-provider-error-body-secret",
         retry_after_seconds: 30
       }}
    end

    def exchange_code(code, _verifier, _redirect_uri, _config, opts) do
      scopes =
        if code == "missing-scope-code" do
          []
        else
          opts
          |> Keyword.fetch!(:required_scopes)
          |> Enum.reject(&(&1 == MicrosoftScopes.offline()))
        end

      {:ok,
       %Token{
         access_token: "microsoft-access-token-private-sentinel",
         refresh_token: "microsoft-refresh-token-private-sentinel",
         expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
         scopes: scopes
       }}
    end

    @impl true
    def refresh_token(_refresh_token, _config, _opts), do: raise("not used")

    @impl true
    def identity("microsoft-access-token-private-sentinel", _config, _opts) do
      identity = Application.fetch_env!(:manifold_connectors, :microsoft_web_test_identity)
      {:ok, %Identity{id: identity.subject, email_address: identity.email_address}}
    end

    @impl true
    def initial_cursors(_access_token, _config, _opts) do
      {:ok, [%SyncCursor{scope: "mailbox", phase: "bootstrap"}]}
    end

    @impl true
    def sync_page(_access_token, cursor, _config, _opts), do: {:ok, %Page{cursor: cursor}}

    @impl true
    def fetch_raw(_access_token, _message_id, _config, _opts) do
      {:ok, %RawMessage{bytes: "Subject: test\r\n\r\nBody\r\n"}}
    end
  end

  setup do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_adapters = Application.get_env(:manifold_connectors, :adapters)
    old_providers = Application.get_env(:manifold_connectors, :providers)
    old_transport = Application.get_env(:manifold_connectors, :imap_transport)
    old_fake = Application.get_env(:manifold_connectors, :imap_fake)
    old_eas_transport = Application.get_env(:manifold_connectors, :eas_transport)
    old_eas_fake = Application.get_env(:manifold_connectors, :eas_fake)
    old_oauth_exchange_probe = Application.get_env(:manifold_connectors, :oauth_exchange_probe)

    old_microsoft_identity =
      Application.get_env(:manifold_connectors, :microsoft_web_test_identity)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :adapters,
      gmail: GmailProvider,
      microsoft: MicrosoftProvider
    )

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        authorization_url: "https://accounts.google.test/o/oauth2/v2/auth"
      ],
      microsoft: [
        client_id: "microsoft-client-secret-id",
        client_secret: "microsoft-client-secret",
        authorization_url: "https://login.microsoft.test/oauth2/v2.0/authorize"
      ]
    )

    Application.put_env(:manifold_connectors, :imap_transport, Manifold.Connectors.IMAP.Fake)

    Application.put_env(:manifold_connectors, :imap_fake, %{
      password_expected: "secret",
      messages: [],
      uidvalidity: 1
    })

    Application.put_env(:manifold_connectors, :eas_transport, Manifold.Connectors.EAS.Fake)

    Application.put_env(:manifold_connectors, :eas_fake, %{
      password_expected: "secret",
      messages: []
    })

    assert {:ok, gmail_setting} =
             Connectors.put_oauth_provider_setting("gmail", %{
               "client_id" => "gmail-client-secret-id",
               "client_secret" => "gmail-client-secret"
             })

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:adapters, old_adapters)
      restore_env(:providers, old_providers)
      restore_env(:imap_transport, old_transport)
      restore_env(:imap_fake, old_fake)
      restore_env(:eas_transport, old_eas_transport)
      restore_env(:eas_fake, old_eas_fake)
      restore_env(:oauth_exchange_probe, old_oauth_exchange_probe)
      restore_env(:microsoft_web_test_identity, old_microsoft_identity)
    end)

    {:ok, account} =
      Accounts.create_account(%{
        name: "Person",
        address: "person@gmail.example"
      })

    {:ok, account: account, gmail_setting: gmail_setting}
  end

  test "settings accounts lists local accounts", %{conn: conn, account: account} do
    assert {:ok, view, html} = live(conn, "/settings/accounts")
    assert has_element?(view, "#add-account-button", "Add account")
    assert html =~ Accounts.account_address(account)
  end

  test "OAuth start and callback connect a receive method to the account", %{
    conn: conn,
    account: account
  } do
    start_conn =
      get(conn, "/connectors/gmail/start", %{
        "account_id" => account.id
      })

    authorization_url = redirected_to(start_conn, 302)
    assert URI.parse(authorization_url).host == "accounts.google.test"

    state =
      authorization_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    callback_conn =
      conn
      |> recycle()
      |> get("/connectors/gmail/callback", %{"code" => "valid-code", "state" => state})

    assert redirected_to(callback_conn, 302) == "/settings/accounts/#{account.id}"

    assert [method] = Connectors.list_receive_methods_for_account(account.id)
    assert method.account_id == account.id
    assert method.kind == "gmail"
    assert method.enabled
  end

  test "Gmail generation changes return only the generic invalid authorization response", %{
    conn: conn,
    account: account,
    gmail_setting: gmail_setting
  } do
    start_conn =
      get(conn, "/connectors/gmail/start", %{
        "account_id" => account.id,
        "purpose" => "receive"
      })

    state = start_conn |> redirected_to(302) |> oauth_state()

    assert {:ok, _rotated} =
             Connectors.put_oauth_provider_setting(
               "gmail",
               %{"client_id" => "rotated-client", "client_secret" => "rotated-secret"},
               expected_lock_version: gmail_setting.lock_version
             )

    callback_conn =
      conn
      |> recycle()
      |> get("/connectors/gmail/callback", %{"code" => "valid-code", "state" => state})

    assert redirected_to(callback_conn, 302) == "/settings/accounts"

    assert Phoenix.Flash.get(callback_conn.assigns.flash, :error) ==
             "The Gmail authorization request is invalid or expired."

    refute inspect(callback_conn.assigns.flash) =~ "configuration"
    refute inspect(callback_conn.assigns.flash) =~ "rotated"
  end

  test "pre-cutover Gmail state is consumed without reaching provider exchange", %{
    conn: conn,
    account: account
  } do
    Application.put_env(:manifold_connectors, :oauth_exchange_probe, self())
    state = "pre-cutover-state-#{System.unique_integer([:positive])}"
    redirect_uri = "http://www.example.com/connectors/gmail/callback"

    assert {:ok, ciphertext} =
             Crypto.encrypt("pre-cutover-verifier", "oauth:gmail:#{account.id}")

    %OAuthTransaction{}
    |> Ecto.Changeset.change(%{
      state_digest: :crypto.hash(:sha256, state),
      provider: "gmail",
      mailbox_id: account.id,
      purpose: "receive",
      required_scopes: [],
      pkce_verifier_ciphertext: ciphertext,
      redirect_uri: redirect_uri,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
    })
    |> Repo.insert!()

    callback_conn =
      get(conn, "/connectors/gmail/callback", %{
        "code" => "pre-cutover-code",
        "state" => state
      })

    assert redirected_to(callback_conn, 302) == "/settings/accounts"

    assert Phoenix.Flash.get(callback_conn.assigns.flash, :error) ==
             "The Gmail authorization request is invalid or expired."

    refute_received :pre_cutover_exchange_called

    replay_conn =
      callback_conn
      |> recycle()
      |> get("/connectors/gmail/callback", %{
        "code" => "pre-cutover-code",
        "state" => state
      })

    assert redirected_to(replay_conn, 302) == "/settings/accounts"
    refute_received :pre_cutover_exchange_called
  end

  test "receive and send pickers preserve their OAuth purpose", %{conn: conn, account: account} do
    {:ok, receive_view, _html} =
      live(conn, ~p"/settings/accounts/#{account.id}/receive_methods/new")

    receive_view |> element("button[phx-value-kind='gmail']") |> render_click()

    assert has_element?(
             receive_view,
             ~s|a[href*="/connectors/gmail/start?account_id=#{account.id}&purpose=receive"]|
           )

    {:ok, send_view, html} = live(conn, ~p"/settings/accounts/#{account.id}/send_methods/new")
    assert html =~ "Choose send method"

    send_view |> element("#send-method-gmail") |> render_click()

    assert has_element?(
             send_view,
             ~s|a[href*="/connectors/gmail/start?account_id=#{account.id}&purpose=send"]|
           )
  end

  test "Gmail send callback creates the bound account method", %{conn: conn, account: account} do
    callback_conn = connect_gmail(conn, account.id, "send")

    assert redirected_to(callback_conn, 302) == "/settings/accounts/#{account.id}"

    assert Phoenix.Flash.get(callback_conn.assigns.flash, :info) ==
             "Gmail send method connected."

    assert [%{account_id: account_id, kind: "gmail", enabled: true}] =
             Connectors.list_send_methods_for_account(account.id)

    assert account_id == account.id
    assert Connectors.list_receive_methods_for_account(account.id) == []
  end

  test "receive-only Gmail access offers an incremental send upgrade", %{
    conn: conn,
    account: account
  } do
    connect_gmail(conn, account.id, "receive")

    {:ok, view, _html} = live(conn, ~p"/settings/accounts/#{account.id}")

    assert has_element?(view, "#upgrade-gmail-access", "Upgrade Gmail access")

    assert has_element?(
             view,
             ~s|#upgrade-gmail-access[href*="account_id=#{account.id}&purpose=send"]|
           )
  end

  test "reconnect-required shared Gmail access renders one reconnect action", %{
    conn: conn,
    account: account
  } do
    connect_gmail(conn, account.id, "receive")
    connect_gmail(conn, account.id, "send")
    authorization = Repo.get_by!(OAuthAuthorization, account_id: account.id, provider: "gmail")

    assert {:ok, _authorization} =
             Connectors.mark_oauth_reconnect_required(
               authorization.id,
               %ProviderError{
                 class: :reconnect,
                 code: :invalid_grant,
                 message: "provider detail must not be shown"
               }
             )

    {:ok, view, html} = live(conn, ~p"/settings/accounts/#{account.id}")

    assert html =~ "both receive and send are paused"
    assert length(Regex.scan(~r/id="reconnect-gmail"/, html)) == 1

    assert has_element?(
             view,
             ~s|#reconnect-gmail[href*="account_id=#{account.id}&purpose=receive"]|,
             "Reconnect Gmail"
           )
  end

  test "Gmail authorization cannot cross-bind its subject to another account", %{
    conn: conn,
    account: account
  } do
    connect_gmail(conn, account.id, "receive")

    {:ok, other} =
      Accounts.create_account(%{name: "Other", address: "other@gmail.example"})

    callback_conn = connect_gmail(conn, other.id, "send")

    assert redirected_to(callback_conn, 302) == "/settings/accounts/#{other.id}"

    assert Phoenix.Flash.get(callback_conn.assigns.flash, :error) ==
             "The Gmail account could not be connected."

    assert Connectors.list_send_methods_for_account(other.id) == []
    assert Repo.aggregate(OAuthAuthorization, :count) == 1
  end

  test "Microsoft Send OAuth is purpose-correct, account-scoped, and returns to the selected account",
       %{
         conn: conn,
         account: account
       } do
    set_microsoft_identity!(Accounts.account_address(account), "microsoft-account-1")

    {:ok, other} =
      Accounts.create_account(%{name: "Other Microsoft", address: "other@microsoft.example"})

    {:ok, view, _html} = live(conn, ~p"/settings/accounts/#{account.id}/send_methods/new")
    view |> element("#send-method-microsoft") |> render_click()

    assert has_element?(
             view,
             ~s|a[href="/connectors/microsoft/start?account_id=#{account.id}&purpose=send"]|
           )

    start_conn =
      get(conn, "/connectors/microsoft/start", %{
        "account_id" => account.id,
        "purpose" => "send"
      })

    authorization_url = redirected_to(start_conn, 302)
    state = oauth_state(authorization_url)

    transaction = Repo.get_by!(OAuthTransaction, state_digest: :crypto.hash(:sha256, state))
    assert transaction.mailbox_id == account.id
    assert transaction.purpose == "send"

    callback_conn =
      conn
      |> recycle()
      |> get("/connectors/microsoft/callback", %{
        "code" => "valid-code",
        "state" => state,
        "account_id" => other.id
      })

    assert redirected_to(callback_conn, 302) == "/settings/accounts/#{account.id}"

    assert Phoenix.Flash.get(callback_conn.assigns.flash, :info) ==
             "Microsoft 365 send method connected."

    assert [%{account_id: account_id, kind: "microsoft", enabled: true}] =
             Connectors.list_send_methods_for_account(account.id)

    assert account_id == account.id
    assert Connectors.list_send_methods_for_account(other.id) == []

    replay_conn =
      callback_conn
      |> recycle()
      |> get("/connectors/microsoft/callback", %{
        "code" => "valid-code",
        "state" => state,
        "account_id" => other.id
      })

    assert redirected_to(replay_conn, 302) == "/settings/accounts"

    assert Phoenix.Flash.get(replay_conn.assigns.flash, :error) ==
             "The Microsoft 365 authorization request is invalid or expired."

    assert Connectors.list_send_methods_for_account(other.id) == []
  end

  test "Microsoft callback failures use safe account-aware flash text", %{
    conn: conn,
    account: account
  } do
    address = Accounts.account_address(account)
    set_microsoft_identity!(address, "microsoft-original-subject")

    assert redirected_to(connect_microsoft(conn, account.id, "send", "valid-code"), 302) ==
             "/settings/accounts/#{account.id}"

    set_microsoft_identity!(address, "microsoft-different-subject")

    subject_mismatch =
      connect_microsoft(conn, account.id, "send", "subject-mismatch-code")

    assert_safe_microsoft_account_error(subject_mismatch, account.id, [
      "microsoft-original-subject",
      "microsoft-different-subject"
    ])

    {:ok, address_account} =
      Accounts.create_account(%{name: "Address mismatch", address: "address@microsoft.example"})

    set_microsoft_identity!("different-address@microsoft.example", "address-mismatch-subject")

    address_mismatch =
      connect_microsoft(conn, address_account.id, "send", "address-mismatch-code")

    assert_safe_microsoft_account_error(address_mismatch, address_account.id, [
      "different-address@microsoft.example",
      "address-mismatch-subject"
    ])

    {:ok, scope_account} =
      Accounts.create_account(%{name: "Scope mismatch", address: "scope@microsoft.example"})

    set_microsoft_identity!(Accounts.account_address(scope_account), "scope-subject")
    missing_scope = connect_microsoft(conn, scope_account.id, "send", "missing-scope-code")

    assert_safe_microsoft_account_error(missing_scope, scope_account.id, [
      MicrosoftScopes.send(),
      MicrosoftScopes.offline()
    ])

    {:ok, provider_account} =
      Accounts.create_account(%{name: "Provider failure", address: "provider@microsoft.example"})

    set_microsoft_identity!(Accounts.account_address(provider_account), "provider-subject")

    provider_failure =
      connect_microsoft(conn, provider_account.id, "send", "provider-failure-code")

    assert_safe_microsoft_account_error(provider_failure, provider_account.id, [
      "raw-microsoft-provider-error-body-secret"
    ])

    {:ok, expired_account} =
      Accounts.create_account(%{name: "Expired", address: "expired@microsoft.example"})

    set_microsoft_identity!(Accounts.account_address(expired_account), "expired-subject")

    {expired_start, expired_state} = start_microsoft(conn, expired_account.id, "send")
    assert URI.parse(redirected_to(expired_start, 302)).host == "login.microsoft.test"

    OAuthTransaction
    |> Repo.get_by!(state_digest: :crypto.hash(:sha256, expired_state))
    |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    expired_callback =
      conn
      |> recycle()
      |> get("/connectors/microsoft/callback", %{
        "code" => "valid-code",
        "state" => expired_state
      })

    assert redirected_to(expired_callback, 302) == "/settings/accounts"

    assert Phoenix.Flash.get(expired_callback.assigns.flash, :error) ==
             "The Microsoft 365 authorization request is invalid or expired."

    refute inspect(expired_callback.assigns.flash) =~ expired_state
    refute inspect(expired_callback.assigns.flash) =~ "expired-subject"
  end

  test "OAuth start rejects unsupported purposes without creating a transaction", %{
    conn: conn,
    account: account
  } do
    response =
      get(conn, "/connectors/gmail/start", %{
        "account_id" => account.id,
        "purpose" => "delete"
      })

    assert redirected_to(response, 302) == "/settings/accounts"

    assert Phoenix.Flash.get(response.assigns.flash, :error) ==
             "The account connection could not be started."

    assert Repo.aggregate(OAuthTransaction, :count) == 0
  end

  test "account show can add IMAP receive method", %{conn: conn, account: account} do
    {:ok, view, _html} =
      live(conn, ~p"/settings/accounts/#{account.id}/receive_methods/new")

    view |> element("button[phx-value-kind='imap']") |> render_click()

    html =
      view
      |> form("#imap-account-form", %{
        imap: %{
          email_address: Accounts.account_address(account),
          username: Accounts.account_address(account),
          password: "secret",
          host: "imap.example",
          port: "993",
          tls_mode: "tls"
        }
      })
      |> render_submit()

    assert html =~ "Saving"
    assert_redirect(view, ~p"/settings/accounts/#{account.id}")

    {:ok, show_view, html} = live(conn, ~p"/settings/accounts/#{account.id}")
    assert html =~ "IMAP"
    assert html =~ "Yes"
    assert render(show_view) =~ "IMAP"

    [method] = Connectors.list_receive_methods_for_account(account.id)
    assert method.kind == "imap"
    assert method.enabled
  end

  test "account show can add EAS receive method", %{conn: conn, account: account} do
    {:ok, view, _html} =
      live(conn, ~p"/settings/accounts/#{account.id}/receive_methods/new")

    view |> element("button[phx-value-kind='eas']") |> render_click()

    html =
      view
      |> form("#eas-account-form", %{
        eas: %{
          email_address: Accounts.account_address(account),
          username: Accounts.account_address(account),
          password: "secret",
          host: "mail.example",
          port: "443",
          path: "/Microsoft-Server-ActiveSync"
        }
      })
      |> render_submit()

    assert html =~ "Saving"
    assert_redirect(view, ~p"/settings/accounts/#{account.id}")

    {:ok, show_view, html} = live(conn, ~p"/settings/accounts/#{account.id}")
    assert html =~ "EAS"
    assert html =~ "Yes"
    assert render(show_view) =~ "EAS"

    [method] = Connectors.list_receive_methods_for_account(account.id)
    assert method.kind == "eas"
    assert method.enabled
  end

  test "eas test connection succeeds without creating a receive method", %{
    conn: conn,
    account: account
  } do
    {:ok, view, _html} =
      live(conn, ~p"/settings/accounts/#{account.id}/receive_methods/new")

    view |> element("button[phx-value-kind='eas']") |> render_click()

    view
    |> form("#eas-account-form", %{
      eas: %{
        email_address: Accounts.account_address(account),
        username: Accounts.account_address(account),
        password: "secret",
        host: "mail.example",
        port: "443",
        path: "/Microsoft-Server-ActiveSync"
      }
    })
    |> render_change()

    html = view |> element("#test-eas-connection") |> render_click()

    refute html =~ "Connection succeeded."
    html = render_async(view)
    assert html =~ "Connection succeeded."
    assert Connectors.list_receive_methods_for_account(account.id) == []
  end

  test "imap test connection succeeds without creating a receive method", %{
    conn: conn,
    account: account
  } do
    {:ok, view, _html} =
      live(conn, ~p"/settings/accounts/#{account.id}/receive_methods/new")

    view |> element("button[phx-value-kind='imap']") |> render_click()

    view
    |> form("#imap-account-form", %{
      imap: %{
        email_address: Accounts.account_address(account),
        username: Accounts.account_address(account),
        password: "secret",
        host: "imap.example",
        port: "993",
        tls_mode: "tls"
      }
    })
    |> render_change()

    html = view |> element("#test-imap-connection") |> render_click()

    refute html =~ "Connection succeeded."
    html = render_async(view)
    assert html =~ "Connection succeeded."
    assert Connectors.list_receive_methods_for_account(account.id) == []
  end

  test "imap test connection failure does not create a receive method", %{
    conn: conn,
    account: account
  } do
    {:ok, view, _html} =
      live(conn, ~p"/settings/accounts/#{account.id}/receive_methods/new")

    view |> element("button[phx-value-kind='imap']") |> render_click()

    view
    |> form("#imap-account-form", %{
      imap: %{
        email_address: Accounts.account_address(account),
        username: Accounts.account_address(account),
        password: "wrong",
        host: "imap.example",
        port: "993",
        tls_mode: "tls"
      }
    })
    |> render_change()

    view |> element("#test-imap-connection") |> render_click()

    html = render_async(view)
    assert html =~ "IMAP authentication failed"
    assert Connectors.list_receive_methods_for_account(account.id) == []
  end

  test "account show can disconnect and remove receive method", %{conn: conn, account: account} do
    connect_gmail(conn, account.id)

    {:ok, view, _html} = live(conn, ~p"/settings/accounts/#{account.id}")

    [method] = Connectors.list_receive_methods_for_account(account.id)

    view
    |> element("#receive-method-#{method.id} button[phx-click=disconnect]")
    |> render_click()

    assert [%{status: "disconnected", enabled: false}] =
             Connectors.list_receive_methods_for_account(account.id)

    view
    |> element("#receive-method-#{method.id} button[phx-click=remove]")
    |> render_click()

    assert Connectors.list_receive_methods_for_account(account.id) == []
  end

  defp set_microsoft_identity!(email_address, subject) do
    Application.put_env(:manifold_connectors, :microsoft_web_test_identity, %{
      email_address: email_address,
      subject: subject
    })
  end

  defp connect_microsoft(conn, account_id, purpose, code) do
    {_start_conn, state} = start_microsoft(conn, account_id, purpose)

    conn
    |> recycle()
    |> get("/connectors/microsoft/callback", %{"code" => code, "state" => state})
  end

  defp start_microsoft(conn, account_id, purpose) do
    start_conn =
      get(conn, "/connectors/microsoft/start", %{
        "account_id" => account_id,
        "purpose" => purpose
      })

    authorization_url = redirected_to(start_conn, 302)
    {start_conn, oauth_state(authorization_url)}
  end

  defp oauth_state(authorization_url) do
    authorization_url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("state")
  end

  defp assert_safe_microsoft_account_error(conn, account_id, secrets) do
    assert redirected_to(conn, 302) == "/settings/accounts/#{account_id}"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "The Microsoft 365 account could not be connected."

    inspected = inspect(conn.assigns.flash)

    for secret <-
          secrets ++
            [
              "microsoft-access-token-private-sentinel",
              "microsoft-refresh-token-private-sentinel"
            ] do
      refute inspected =~ secret
    end
  end

  defp connect_gmail(conn, account_id, purpose \\ "receive") do
    start_conn =
      get(conn, "/connectors/gmail/start", %{
        "account_id" => account_id,
        "purpose" => purpose
      })

    authorization_url = redirected_to(start_conn, 302)

    state =
      authorization_url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    conn
    |> recycle()
    |> get("/connectors/gmail/callback", %{"code" => "valid-code", "state" => state})
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

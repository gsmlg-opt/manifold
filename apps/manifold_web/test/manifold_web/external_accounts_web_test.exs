defmodule ManifoldWeb.ExternalAccountsWebTest do
  use ManifoldWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Provider.{Identity, Page, RawMessage, Token}
  alias Manifold.Connectors.Provider.SyncCursor, as: ProviderCursor

  defmodule GmailProvider do
    @behaviour Manifold.Connectors.Provider

    @impl true
    def exchange_code("valid-code", _verifier, _redirect_uri, _config, _opts) do
      {:ok,
       %Token{
         access_token: "gmail-access-token",
         refresh_token: "gmail-refresh-token",
         expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
         scopes: ["openid", "email", "https://www.googleapis.com/auth/gmail.readonly"]
       }}
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

  setup do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_adapters = Application.get_env(:manifold_connectors, :adapters)
    old_providers = Application.get_env(:manifold_connectors, :providers)
    old_transport = Application.get_env(:manifold_connectors, :imap_transport)
    old_fake = Application.get_env(:manifold_connectors, :imap_fake)
    old_eas_transport = Application.get_env(:manifold_connectors, :eas_transport)
    old_eas_fake = Application.get_env(:manifold_connectors, :eas_fake)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :adapters, gmail: GmailProvider)

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        client_id: "gmail-client-secret-id",
        client_secret: "gmail-client-secret",
        authorization_url: "https://accounts.google.test/o/oauth2/v2/auth"
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

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:adapters, old_adapters)
      restore_env(:providers, old_providers)
      restore_env(:imap_transport, old_transport)
      restore_env(:imap_fake, old_fake)
      restore_env(:eas_transport, old_eas_transport)
      restore_env(:eas_fake, old_eas_fake)
    end)

    {:ok, account} =
      Accounts.create_account(%{
        name: "Person",
        address: "person@external-web-#{System.unique_integer([:positive])}.test"
      })

    {:ok, account: account}
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

  defp connect_gmail(conn, account_id) do
    start_conn = get(conn, "/connectors/gmail/start", %{"account_id" => account_id})
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

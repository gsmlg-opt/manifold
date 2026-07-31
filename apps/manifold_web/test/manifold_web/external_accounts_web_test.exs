defmodule ManifoldWeb.ExternalAccountsWebTest do
  use ManifoldWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.OAuth
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
    def request_device_code(_config, _opts),
      do:
        {:error,
         %Manifold.Connectors.Provider.Error{
           class: :permanent,
           code: :device_flow_unsupported,
           message: "not used"
         }}

    @impl true
    def exchange_device_code(_device_code, _config, _opts),
      do:
        {:error,
         %Manifold.Connectors.Provider.Error{
           class: :permanent,
           code: :device_flow_unsupported,
           message: "not used"
         }}

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

    @impl true
    def exchange_code(_code, _verifier, _redirect_uri, _config, _opts) do
      {:error,
       %Manifold.Connectors.Provider.Error{
         class: :permanent,
         code: :authorization_code_unsupported,
         message: "use device flow"
       }}
    end

    @impl true
    def request_device_code(_config, opts) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      {:ok,
       %Manifold.Connectors.Provider.DeviceCode{
         device_code: "device-code-secret",
         user_code: "ABCD-EFGH",
         verification_uri: "https://microsoft.com/devicelogin",
         verification_uri_complete: "https://microsoft.com/devicelogin?otc=ABCD-EFGH",
         interval_seconds: 1,
         expires_at: DateTime.add(now, 600, :second)
       }}
    end

    @impl true
    def exchange_device_code("device-code-secret", _config, _opts) do
      case Application.get_env(:manifold_connectors, :test_device_poll_result, :token) do
        :pending ->
          {:pending, :authorization_pending}

        :declined ->
          {:error,
           %Manifold.Connectors.Provider.Error{
             class: :permanent,
             code: :authorization_declined,
             message: "declined"
           }}

        :token ->
          {:ok,
           %Token{
             access_token: "microsoft-access-token",
             refresh_token: "microsoft-refresh-token",
             expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
             scopes: ["openid", "profile", "offline_access", "User.Read", "Mail.Read"]
           }}
      end
    end

    def exchange_device_code(_device_code, _config, _opts) do
      {:error,
       %Manifold.Connectors.Provider.Error{
         class: :permanent,
         code: :invalid_grant,
         message: "invalid device code"
       }}
    end

    @impl true
    def refresh_token(_refresh_token, _config, _opts), do: raise("not used")

    @impl true
    def identity("microsoft-access-token", _config, _opts) do
      {:ok, %Identity{id: "microsoft-account-1", email_address: "person@outlook.example"}}
    end

    @impl true
    def initial_cursors("microsoft-access-token", _config, _opts) do
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

    Application.put_env(:manifold_connectors, :adapters,
      gmail: GmailProvider,
      microsoft: MicrosoftProvider
    )

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        client_id: "gmail-client-id",
        authorization_url: "https://accounts.google.test/o/oauth2/v2/auth",
        token_url: "https://oauth.google.test/token"
      ],
      microsoft: [
        client_id: "microsoft-client-id",
        device_code_url: "https://login.microsoft.test/oauth2/v2.0/devicecode",
        token_url: "https://login.microsoft.test/oauth2/v2.0/token"
      ]
    )

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:adapters, old_adapters)
      restore_env(:providers, old_providers)
      Application.delete_env(:manifold_connectors, :test_device_poll_result)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "external-web-#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_mailbox(domain, %{local_part: "person"})

    {:ok, domain: domain, mailbox: mailbox}
  end

  test "settings accounts opens with an add account button that navigates to new", %{conn: conn} do
    assert {:ok, view, html} = live(conn, "/settings/accounts")

    assert has_element?(view, "#add-account-button", "Add account")
    assert has_element?(view, "#add-account-button[href='/settings/accounts/new']")
    refute has_element?(view, "#add-account-panel")
    refute html =~ "/connectors/gmail/start"
    refute html =~ "/connectors/microsoft/start"
    refute html =~ "Log in"
  end

  test "add account button navigates to the new account page", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, "/settings/accounts")

    assert {:ok, new_view, html} =
             view
             |> element("#add-account-button")
             |> render_click()
             |> follow_redirect(conn, "/settings/accounts/new")

    assert html =~ "What kind of account are you adding?"
    assert has_element?(new_view, "#add-account-panel")
    assert has_element?(new_view, "#external-account-type")
  end

  test "external account wizard selects a provider and mailbox", %{conn: conn, mailbox: mailbox} do
    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")

    assert render(view) =~ "External account"

    html =
      view
      |> element("#external-account-type")
      |> render_click()

    assert html =~ "Choose a provider"
    assert has_element?(view, "#provider-gmail:not([disabled])")
    assert has_element?(view, "#provider-microsoft:not([disabled])")

    html = view |> element("#provider-gmail") |> render_click()

    assert html =~ "Choose a local mailbox"
    refute has_element?(view, "#continue-add-account")

    html =
      view
      |> form("#add-account-mailbox-form", %{mailbox_id: mailbox.id})
      |> render_change()

    assert has_element?(
             view,
             "#continue-add-account[href='/connectors/gmail/start?mailbox_id=#{mailbox.id}']",
             "Sign in with Google"
           )

    assert html =~ "Sign in with Google"
  end

  test "external account wizard creates a Microsoft device authorization handoff", %{
    conn: conn,
    mailbox: mailbox
  } do
    Application.put_env(:manifold_connectors, :test_device_poll_result, :pending)

    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")
    open_provider_step(view)

    view
    |> element("#provider-microsoft")
    |> render_click()

    view
    |> form("#add-account-mailbox-form", %{mailbox_id: mailbox.id})
    |> render_change()

    assert has_element?(view, "#continue-add-account", "Sign in with Microsoft")

    html = view |> element("#continue-add-account") |> render_click()

    assert html =~ "Approve Microsoft 365 access"
    assert has_element?(view, "#device-user-code", "ABCD-EFGH")
    assert has_element?(view, "#device-verification-link", "https://microsoft.com/devicelogin")
    assert has_element?(view, "#device-waiting", "Waiting for authorization")
  end

  test "Microsoft device authorization connects the account after polling", %{
    conn: conn,
    mailbox: mailbox
  } do
    Application.put_env(:manifold_connectors, :test_device_poll_result, :token)

    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")
    open_provider_step(view)

    view
    |> element("#provider-microsoft")
    |> render_click()

    view
    |> form("#add-account-mailbox-form", %{mailbox_id: mailbox.id})
    |> render_change()

    view
    |> element("#continue-add-account")
    |> render_click()

    send(view.pid, :poll_device_authorization)

    assert_redirect(view, "/settings/accounts")

    assert [account] = Connectors.list_accounts()
    assert account.mailbox_id == mailbox.id
    assert account.provider == "microsoft"
    assert account.email_address == "person@outlook.example"
  end

  test "wizard rejects forward events before account type selection", %{
    conn: conn,
    mailbox: mailbox
  } do
    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")

    render_hook(view, "choose-provider", %{"provider" => "gmail"})
    render_hook(view, "select-add-account-mailbox", %{"mailbox_id" => mailbox.id})

    refute has_element?(view, "#continue-add-account")
    assert has_element?(view, "#add-account-type-heading")

    assert {:ok, socket} = Phoenix.LiveView.Debug.socket(view.pid)

    assert %{
             add_account_step: :account_type,
             selected_provider: nil,
             selected_mailbox_id: nil
           } = socket.assigns
  end

  test "wizard rejects a provider before account type selection", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")

    assert render_hook(view, "choose-provider", %{"provider" => "gmail"}) =~
             "What kind of account are you adding?"

    refute has_element?(view, "#continue-add-account")

    assert {:ok, socket} = Phoenix.LiveView.Debug.socket(view.pid)

    assert %{
             add_account_step: :account_type,
             selected_provider: nil,
             selected_mailbox_id: nil
           } = socket.assigns
  end

  test "wizard rejects a mailbox before provider selection", %{conn: conn, mailbox: mailbox} do
    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")
    open_provider_step(view)

    assert render_hook(view, "select-add-account-mailbox", %{"mailbox_id" => mailbox.id}) =~
             "Choose a provider"

    refute has_element?(view, "#continue-add-account")

    assert {:ok, socket} = Phoenix.LiveView.Debug.socket(view.pid)

    assert %{
             add_account_step: :provider,
             selected_provider: nil,
             selected_mailbox_id: nil
           } = socket.assigns
  end

  test "add account panel is descriptively labelled without duplicate live announcements", %{
    conn: conn
  } do
    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")

    assert has_element?(
             view,
             "#add-account-panel[aria-labelledby='add-account-title'] #add-account-title",
             "Add an email account"
           )

    refute has_element?(view, "#add-account-panel[aria-live]")
    refute has_element?(view, "#add-account-panel[aria-atomic]")
  end

  test "wizard ignores forged account type and provider values", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")

    assert render_hook(view, "choose-account-type", %{"type" => "local"}) =~
             "What kind of account are you adding?"

    assert render_hook(view, "choose-account-type", %{}) =~ "What kind of account are you adding?"

    view
    |> element("#external-account-type")
    |> render_click()

    assert render_hook(view, "choose-provider", %{"provider" => "imap"}) =~
             "Choose a provider"

    assert render_hook(view, "choose-provider", %{}) =~ "Choose a provider"
    refute has_element?(view, "#continue-add-account")
  end

  test "wizard clears the mailbox selection for forged values", %{conn: conn, mailbox: mailbox} do
    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")
    open_provider_step(view)

    view
    |> element("#provider-gmail")
    |> render_click()

    view
    |> form("#add-account-mailbox-form", %{mailbox_id: mailbox.id})
    |> render_change()

    assert has_element?(view, "#continue-add-account")

    assert render_hook(view, "select-add-account-mailbox", %{"mailbox_id" => "unknown"}) =~
             "Choose a local mailbox"

    refute has_element?(view, "#continue-add-account")

    assert render_hook(view, "select-add-account-mailbox", %{}) =~ "Choose a local mailbox"
    refute has_element?(view, "#continue-add-account")
  end

  test "OAuth start and callback consume matching state and connect the account", %{
    conn: conn,
    mailbox: mailbox
  } do
    start_conn =
      get(conn, "/connectors/gmail/start", %{
        "mailbox_id" => mailbox.id
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

    assert redirected_to(callback_conn, 302) == "/settings/accounts"
    assert Phoenix.Flash.get(callback_conn.assigns.flash, :info) == "Gmail account connected."

    assert [account] = Connectors.list_accounts()
    assert account.mailbox_id == mailbox.id
    assert account.provider == "gmail"
  end

  test "Microsoft connector start route directs operators to device authorization", %{conn: conn} do
    start_conn = get(conn, "/connectors/microsoft/start", %{"mailbox_id" => Ecto.UUID.generate()})

    assert redirected_to(start_conn, 302) == "/settings/accounts"

    assert Phoenix.Flash.get(start_conn.assigns.flash, :error) =~
             "Microsoft 365 uses device authorization"
  end

  test "OAuth callback rejects tampered state without connecting an account", %{conn: conn} do
    callback_conn =
      get(conn, "/connectors/gmail/callback", %{
        "code" => "valid-code",
        "state" => "tampered-state"
      })

    assert redirected_to(callback_conn, 302) == "/settings/accounts"

    assert Phoenix.Flash.get(callback_conn.assigns.flash, :error) ==
             "The Gmail authorization request is invalid or expired."

    assert Connectors.list_accounts() == []
  end

  test "account actions enqueue sync and disconnect through the public context", %{
    conn: conn,
    mailbox: mailbox
  } do
    connect_account(conn, "microsoft", mailbox.id)

    assert {:ok, view, html} = live(conn, "/settings/accounts")
    assert html =~ "person@outlook.example"
    assert html =~ "Connected"

    assert view
           |> element("button[phx-click=sync]")
           |> render_click() =~ "Synchronization queued."

    html =
      view
      |> element("button[phx-click=disconnect]")
      |> render_click()

    assert html =~ "Disconnected"
    assert [%{status: "disconnected", sync_enabled: false}] = Connectors.list_accounts()
  end

  test "account surface does not expose tokens, client secrets, or storage paths", %{
    conn: conn,
    mailbox: mailbox
  } do
    connect_account(conn, "gmail", mailbox.id)

    assert {:ok, _view, html} = live(conn, "/settings/accounts")

    refute html =~ "gmail-access-token"
    refute html =~ "gmail-refresh-token"
    refute html =~ "gmail-client-secret"
    refute html =~ "spool_bundle_path"
    refute html =~ "raw_object_key"
    refute html =~ "/raw/"
    refute html =~ "/ready/"
  end

  test "unconfigured providers are shown as unavailable", %{conn: conn} do
    Application.put_env(:manifold_connectors, :providers, [])

    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")
    open_provider_step(view)

    html = render(view)

    assert view
           |> element("#provider-gmail[disabled]")
           |> render() =~ "Provider not configured"

    assert view
           |> element("#provider-microsoft[disabled]")
           |> render() =~ "Provider not configured"

    refute html =~ "/connectors/gmail/start"
    refute html =~ "/connectors/microsoft/start"

    assert render_hook(view, "choose-provider", %{"provider" => "gmail"}) =~
             "Choose a provider"

    refute has_element?(view, "#continue-add-account")
  end

  test "inactive mailboxes are not offered as connector destinations", %{
    conn: conn,
    mailbox: mailbox
  } do
    mailbox
    |> Ecto.Changeset.change(active: false)
    |> Manifold.Repo.update!()

    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")
    open_provider_step(view)

    html = view |> element("#provider-gmail") |> render_click()

    refute html =~ mailbox.local_part
    assert html =~ "Create an active local mailbox before connecting an external account."
    assert has_element?(view, "#manage-mailboxes-link[href='/mailboxes']")
    refute has_element?(view, "#continue-add-account")
  end

  test "back moves one step and cancel returns to accounts list", %{conn: conn, mailbox: mailbox} do
    connect_account(conn, "microsoft", mailbox.id)

    assert [%{id: account_id, email_address: "person@outlook.example"}] =
             Connectors.list_accounts()

    assert {:ok, view, _html} = live(conn, "/settings/accounts/new")

    assert has_element?(
             view,
             "#add-account-type-heading[tabindex='-1'][phx-mounted*='focus']",
             "What kind of account are you adding?"
           )

    refute has_element?(view, "#back-add-account")
    assert has_element?(view, "#cancel-add-account")

    view
    |> element("#external-account-type")
    |> render_click()

    assert has_element?(
             view,
             "#add-account-provider-heading[tabindex='-1'][phx-mounted*='focus']",
             "Choose a provider"
           )

    assert has_element?(view, "#back-add-account")
    assert has_element?(view, "#cancel-add-account")

    view
    |> element("#provider-gmail")
    |> render_click()

    assert has_element?(
             view,
             "#add-account-mailbox-heading[tabindex='-1'][phx-mounted*='focus']",
             "Choose a local mailbox"
           )

    assert has_element?(view, "#back-add-account")
    assert has_element?(view, "#cancel-add-account")

    view
    |> form("#add-account-mailbox-form", %{mailbox_id: mailbox.id})
    |> render_change()

    assert has_element?(view, "#continue-add-account")

    assert view
           |> element("#back-add-account")
           |> render_click() =~ "Choose a provider"

    assert has_element?(
             view,
             "#add-account-provider-heading[tabindex='-1'][phx-mounted*='focus']"
           )

    assert has_element?(view, "#back-add-account")
    assert has_element?(view, "#cancel-add-account")

    view
    |> element("#provider-gmail")
    |> render_click()

    refute has_element?(view, "#continue-add-account")

    view
    |> form("#add-account-mailbox-form", %{mailbox_id: mailbox.id})
    |> render_change()

    assert has_element?(view, "#continue-add-account")

    view
    |> element("#back-add-account")
    |> render_click()

    html = view |> element("#back-add-account") |> render_click()

    assert html =~ "What kind of account are you adding?"

    assert has_element?(
             view,
             "#add-account-type-heading[tabindex='-1'][phx-mounted*='focus']"
           )

    refute has_element?(view, "#back-add-account")
    assert has_element?(view, "#cancel-add-account")

    view
    |> element("#external-account-type")
    |> render_click()

    view
    |> element("#provider-gmail")
    |> render_click()

    view
    |> form("#add-account-mailbox-form", %{mailbox_id: mailbox.id})
    |> render_change()

    assert has_element?(view, "#continue-add-account")

    assert {:ok, index_view, html} =
             view
             |> element("#cancel-add-account")
             |> render_click()
             |> follow_redirect(conn, "/settings/accounts")

    assert html =~ "Connected accounts"
    assert html =~ "person@outlook.example"
    assert has_element?(index_view, "#external-account-#{account_id} button[phx-click=sync]")

    assert has_element?(
             index_view,
             "#external-account-#{account_id} button[phx-click=disconnect]"
           )

    refute has_element?(index_view, "#add-account-panel")
    assert has_element?(index_view, "#add-account-button[href='/settings/accounts/new']")
  end

  defp open_provider_step(view) do
    view
    |> element("#external-account-type")
    |> render_click()
  end

  defp connect_account(conn, "gmail", mailbox_id) do
    start_conn = get(conn, "/connectors/gmail/start", %{"mailbox_id" => mailbox_id})

    state =
      start_conn
      |> redirected_to(302)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    conn
    |> recycle()
    |> get("/connectors/gmail/callback", %{"code" => "valid-code", "state" => state})
  end

  defp connect_account(_conn, "microsoft", mailbox_id) do
    Application.put_env(:manifold_connectors, :test_device_poll_result, :token)

    assert {:ok, authorization} = OAuth.start_device("microsoft", mailbox_id)
    assert {:ok, token, consumed} = OAuth.poll_device("microsoft", authorization.state)
    assert {:ok, _account} = Connectors.complete_device_authorization("microsoft", token, consumed)
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

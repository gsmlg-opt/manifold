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

  defmodule MicrosoftProvider do
    @behaviour Manifold.Connectors.Provider

    @impl true
    def exchange_code("valid-code", _verifier, _redirect_uri, _config, _opts) do
      {:ok,
       %Token{
         access_token: "microsoft-access-token",
         refresh_token: "microsoft-refresh-token",
         expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
         scopes: ["openid", "profile", "offline_access", "User.Read", "Mail.Read"]
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
        client_id: "gmail-client-secret-id",
        client_secret: "gmail-client-secret",
        authorization_url: "https://accounts.google.test/o/oauth2/v2/auth"
      ],
      microsoft: [
        client_id: "microsoft-client-secret-id",
        client_secret: "microsoft-client-secret",
        authorization_url: "https://login.microsoft.test/oauth2/v2.0/authorize"
      ]
    )

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:adapters, old_adapters)
      restore_env(:providers, old_providers)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "external-web-#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_mailbox(domain, %{local_part: "person"})

    {:ok, domain: domain, mailbox: mailbox}
  end

  test "settings accounts opens with an add account button", %{conn: conn} do
    assert {:ok, view, html} = live(conn, "/settings/accounts")

    assert has_element?(view, "#add-account-button", "Add account")
    refute has_element?(view, "#add-account-panel")
    refute html =~ "/connectors/gmail/start"
    refute html =~ "/connectors/microsoft/start"
    refute html =~ "Log in"
  end

  test "external account wizard selects a provider and mailbox", %{conn: conn, mailbox: mailbox} do
    assert {:ok, view, _html} = live(conn, "/settings/accounts")

    assert view
           |> element("#add-account-button")
           |> render_click() =~ "External account"

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
             "Continue to Gmail"
           )

    assert html =~ "Continue to Gmail"
  end

  test "external account wizard creates a Microsoft OAuth handoff", %{
    conn: conn,
    mailbox: mailbox
  } do
    assert {:ok, view, _html} = live(conn, "/settings/accounts")
    open_provider_step(view)

    view
    |> element("#provider-microsoft")
    |> render_click()

    view
    |> form("#add-account-mailbox-form", %{mailbox_id: mailbox.id})
    |> render_change()

    assert has_element?(
             view,
             "#continue-add-account[href='/connectors/microsoft/start?mailbox_id=#{mailbox.id}']",
             "Continue to Microsoft 365"
           )
  end

  test "wizard rejects forward events while closed", %{conn: conn, mailbox: mailbox} do
    assert {:ok, view, _html} = live(conn, "/settings/accounts")

    render_hook(view, "choose-account-type", %{"type" => "external"})
    render_hook(view, "choose-provider", %{"provider" => "gmail"})
    render_hook(view, "select-add-account-mailbox", %{"mailbox_id" => mailbox.id})

    refute has_element?(view, "#add-account-panel")
    refute has_element?(view, "#continue-add-account")

    assert {:ok, socket} = Phoenix.LiveView.Debug.socket(view.pid)

    assert %{
             add_account_step: :closed,
             selected_provider: nil,
             selected_mailbox_id: nil
           } = socket.assigns
  end

  test "wizard rejects a provider before account type selection", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, "/settings/accounts")

    view
    |> element("#add-account-button")
    |> render_click()

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
    assert {:ok, view, _html} = live(conn, "/settings/accounts")
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
    assert {:ok, view, _html} = live(conn, "/settings/accounts")

    view
    |> element("#add-account-button")
    |> render_click()

    assert has_element?(
             view,
             "#add-account-panel[aria-labelledby='add-account-title'] #add-account-title",
             "Add an email account"
           )

    refute has_element?(view, "#add-account-panel[aria-live]")
    refute has_element?(view, "#add-account-panel[aria-atomic]")
  end

  test "wizard ignores forged account type and provider values", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, "/settings/accounts")

    view
    |> element("#add-account-button")
    |> render_click()

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
    assert {:ok, view, _html} = live(conn, "/settings/accounts")
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

    assert {:ok, view, _html} = live(conn, "/settings/accounts")
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

    assert {:ok, view, _html} = live(conn, "/settings/accounts")
    open_provider_step(view)

    html = view |> element("#provider-gmail") |> render_click()

    refute html =~ mailbox.local_part
    assert html =~ "Create an active local mailbox before connecting an external account."

    assert has_element?(
             view,
             "#create-local-mailbox-link[href*='provider=gmail'][href*='source=external_account']",
             "Create local mailbox"
           )

    refute has_element?(view, "#continue-add-account")
  end

  test "validated handoff restores provider and mailbox selection", %{
    conn: conn,
    mailbox: mailbox
  } do
    assert {:ok, view, _html} =
             live(conn, ~p"/settings/accounts?#{[provider: "gmail", mailbox_id: mailbox.id]}")

    assert has_element?(view, "#add-account-mailbox-heading", "Choose a local mailbox")

    assert has_element?(
             view,
             "#add-account-mailbox-id option[value='#{mailbox.id}'][selected]"
           )

    assert has_element?(
             view,
             "#continue-add-account[href='/connectors/gmail/start?mailbox_id=#{mailbox.id}']",
             "Continue to Gmail"
           )
  end

  test "invalid handoff parameters fail closed", %{conn: conn, mailbox: mailbox} do
    assert {:ok, forged_provider, _html} =
             live(conn, ~p"/settings/accounts?#{[provider: "imap", mailbox_id: mailbox.id]}")

    refute has_element?(forged_provider, "#add-account-panel")

    assert {:ok, unknown_mailbox, _html} =
             live(
               conn,
               ~p"/settings/accounts?#{[provider: "gmail", mailbox_id: Ecto.UUID.generate()]}"
             )

    refute has_element?(unknown_mailbox, "#add-account-panel")

    mailbox
    |> Ecto.Changeset.change(active: false)
    |> Manifold.Repo.update!()

    assert {:ok, inactive_mailbox, _html} =
             live(conn, ~p"/settings/accounts?#{[provider: "gmail", mailbox_id: mailbox.id]}")

    refute has_element?(inactive_mailbox, "#add-account-panel")
    refute has_element?(inactive_mailbox, "#continue-add-account")
  end

  test "back moves one step and cancel resets account setup", %{conn: conn, mailbox: mailbox} do
    connect_account(conn, "microsoft", mailbox.id)

    assert [%{id: account_id, email_address: "person@outlook.example"}] =
             Connectors.list_accounts()

    assert {:ok, view, _html} = live(conn, "/settings/accounts")

    view
    |> element("#add-account-button")
    |> render_click()

    assert has_element?(
             view,
             "#add-account-type-heading[tabindex='-1'][phx-mounted*='focus']",
             "What kind of account are you adding?"
           )

    refute has_element?(view, "#back-add-account")
    assert has_element?(view, "#cancel-add-account")

    assert has_element?(
             view,
             "#cancel-add-account[phx-click*='cancel-add-account'][phx-click*='focus'][phx-click*='#add-account-button']"
           )

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

    html = view |> element("#cancel-add-account") |> render_click()

    assert {:ok, socket} = Phoenix.LiveView.Debug.socket(view.pid)
    assert socket.assigns.add_account_step == :closed
    assert socket.assigns.selected_provider == nil
    assert socket.assigns.selected_mailbox_id == nil

    assert html =~ "Connected accounts"
    assert html =~ "person@outlook.example"
    assert has_element?(view, "#external-account-#{account_id} button[phx-click=sync]")
    assert has_element?(view, "#external-account-#{account_id} button[phx-click=disconnect]")

    refute has_element?(view, "#add-account-panel")

    html = view |> element("#add-account-button") |> render_click()

    assert html =~ "What kind of account are you adding?"
    refute has_element?(view, "#back-add-account")
    assert has_element?(view, "#cancel-add-account")
    refute html =~ "Choose a provider"
    refute html =~ "Choose a local mailbox"
    refute has_element?(view, "#continue-add-account")
  end

  defp open_provider_step(view) do
    view
    |> element("#add-account-button")
    |> render_click()

    view
    |> element("#external-account-type")
    |> render_click()
  end

  defp connect_account(conn, provider, mailbox_id) do
    start_conn = get(conn, "/connectors/#{provider}/start", %{"mailbox_id" => mailbox_id})

    state =
      start_conn
      |> redirected_to(302)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    conn
    |> recycle()
    |> get("/connectors/#{provider}/callback", %{"code" => "valid-code", "state" => state})
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

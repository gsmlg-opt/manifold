defmodule ManifoldWeb.AccountLiveTest do
  use ManifoldWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Manifold.AccountLifecycle.Jobs.PurgeAccount
  alias Manifold.AccountLifecycle.Schema.AccountPurge
  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.{GmailScopes, MicrosoftScopes}
  alias Manifold.Connectors.Provider.{Page, RawMessage}
  alias Manifold.Connectors.Provider.SyncCursor, as: ProviderCursor
  alias Manifold.Connectors.Schema.{OAuthAuthorization, ReceiveMethod, SendMethod}
  alias Manifold.Repo

  defmodule MicrosoftSetupProvider do
    @behaviour Manifold.Connectors.Provider

    @impl true
    def exchange_code(_code, _verifier, _redirect_uri, _config, _opts), do: raise("not used")

    @impl true
    def refresh_token(_refresh_token, _config, _opts), do: raise("not used")

    @impl true
    def identity(_access_token, _config, _opts), do: raise("not used")

    @impl true
    def initial_cursors(_access_token, _config, _opts) do
      {:ok, [%ProviderCursor{scope: "mailbox", phase: "bootstrap"}]}
    end

    @impl true
    def sync_page(_access_token, cursor, _config, _opts), do: {:ok, %Page{cursor: cursor}}

    @impl true
    def fetch_raw(_access_token, _message_id, _config, _opts) do
      {:ok, %RawMessage{bytes: "Subject: test\r\n\r\nBody\r\n"}}
    end
  end

  setup do
    start_supervised!({Oban, Application.fetch_env!(:manifold_data, Oban)})
    :ok
  end

  test "create account from name and address", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/settings/accounts/new")

    {:ok, _show_view, html} =
      view
      |> form("#account-form", account: %{name: "Alice", address: "alice@example.test"})
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "Alice"
    assert html =~ "alice@example.test"

    [account] = Accounts.list_accounts()
    assert account.name == "Alice"
    assert Accounts.account_address(account) == "alice@example.test"
  end

  test "account show lists receive methods and can remove one", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Bob", address: "bob@example.test"})

    {:ok, method} =
      Connectors.create_placeholder_receive_method(account.id, "pop3")

    {:ok, show_view, html} = live(conn, ~p"/settings/accounts/#{account.id}")
    assert html =~ "bob@example.test"
    assert html =~ ~p"/settings/accounts/#{account.id}/receive_methods/new"
    assert html =~ ~p"/settings/accounts/#{account.id}/send_methods/new"
    assert html =~ "POP3"
    assert html =~ "No send methods configured."

    {:ok, new_view, html} =
      show_view
      |> element("#add-receive-method")
      |> render_click()
      |> follow_redirect(conn, ~p"/settings/accounts/#{account.id}/receive_methods/new")

    refute html =~ ~s(phx-value-kind="pop3")
    refute html =~ ~s(phx-value-kind="ews")
    assert html =~ ~s(phx-value-kind="imap")
    assert html =~ ~s(phx-value-kind="eas")

    {:ok, show_view, html} =
      new_view
      |> element("a", "Cancel")
      |> render_click()
      |> follow_redirect(conn, ~p"/settings/accounts/#{account.id}")

    assert html =~ "POP3"

    show_view
    |> element("#receive-method-#{method.id} button[phx-click=remove]")
    |> render_click()

    assert Connectors.list_receive_methods_for_account(account.id) == []
    refute render(show_view) =~ "POP3"
  end

  test "account show can add smtp send method", %{conn: conn} do
    previous_transport = Application.get_env(:manifold_connectors, :smtp_transport)
    previous_fake = Application.get_env(:manifold_connectors, :smtp_fake)

    Application.put_env(:manifold_connectors, :smtp_transport, Manifold.Connectors.SMTP.Fake)
    Application.put_env(:manifold_connectors, :smtp_fake, %{password_expected: "secret"})

    on_exit(fn ->
      restore_smtp_env(:smtp_transport, previous_transport)
      restore_smtp_env(:smtp_fake, previous_fake)
    end)

    {:ok, account} =
      Accounts.create_account(%{name: "Eve", address: "eve@example.test"})

    {:ok, show_view, _html} = live(conn, ~p"/settings/accounts/#{account.id}")

    {:ok, new_view, html} =
      show_view
      |> element("#add-send-method")
      |> render_click()
      |> follow_redirect(conn, ~p"/settings/accounts/#{account.id}/send_methods/new")

    assert html =~ "Choose send method"
    assert html =~ "Gmail"
    assert html =~ "SMTP"

    html = new_view |> element("#send-method-smtp") |> render_click()
    assert html =~ "SMTP settings"

    html =
      new_view
      |> form("#smtp-send-method-form",
        smtp: %{
          email_address: "eve@example.test",
          host: "smtp.example",
          port: "465",
          tls_mode: "tls",
          username: "eve@example.test",
          password: "secret"
        }
      )
      |> render_submit()

    assert html =~ "Saving"
    assert_redirect(new_view, ~p"/settings/accounts/#{account.id}")

    {:ok, _show_view, html} = live(conn, ~p"/settings/accounts/#{account.id}")
    assert html =~ "SMTP"
    assert html =~ "eve@example.test"

    [method] = Connectors.list_send_methods_for_account(account.id)
    assert method.kind == "smtp"
    assert method.enabled
  end

  test "add send keeps unconfigured Gmail visible but disabled", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "No OAuth", address: "no-oauth@example.test"})

    {:ok, view, html} = live(conn, ~p"/settings/accounts/#{account.id}/send_methods/new")

    assert html =~ "Choose send method"
    assert has_element?(view, "#send-method-gmail[disabled]")
    assert has_element?(view, "#send-method-gmail", "Provider not configured")
    assert has_element?(view, "#send-method-smtp")
  end

  test "Microsoft 365 send remains visible and disabled when provider config is absent", %{
    conn: conn
  } do
    previous_providers = Application.get_env(:manifold_connectors, :providers)
    Application.put_env(:manifold_connectors, :providers, [])

    on_exit(fn -> restore_smtp_env(:providers, previous_providers) end)

    {:ok, account} =
      Accounts.create_account(%{name: "No Microsoft", address: "no-microsoft@example.test"})

    {:ok, view, html} = live(conn, ~p"/settings/accounts/#{account.id}/send_methods/new")

    assert html =~ "Microsoft 365"
    assert has_element?(view, "#send-method-microsoft[disabled]")
    assert has_element?(view, "#send-method-microsoft", "Provider not configured")
  end

  test "Microsoft send setup renders connect upgrade add and connected states without secrets", %{
    conn: conn
  } do
    configure_microsoft_provider!()

    {:ok, connect_account} =
      Accounts.create_account(%{name: "Connect", address: "connect@microsoft-ui.test"})

    {:ok, connect_view, _html} =
      live(conn, ~p"/settings/accounts/#{connect_account.id}/send_methods/new")

    connect_html = connect_view |> element("#send-method-microsoft") |> render_click()
    assert connect_html =~ "Connect Microsoft"

    assert has_element?(
             connect_view,
             ~s|a[href*="account_id=#{connect_account.id}&purpose=send"]|,
             "Continue with Microsoft"
           )

    assert_safe_oauth_html(connect_html, [])

    {:ok, upgrade_account} =
      Accounts.create_account(%{name: "Upgrade", address: "upgrade@microsoft-ui.test"})

    upgrade_authorization =
      insert_microsoft_authorization!(upgrade_account, [MicrosoftScopes.read()])

    insert_microsoft_receive!(upgrade_account, upgrade_authorization)

    {:ok, upgrade_view, _html} =
      live(conn, ~p"/settings/accounts/#{upgrade_account.id}/send_methods/new")

    upgrade_html = upgrade_view |> element("#send-method-microsoft") |> render_click()
    assert upgrade_html =~ "Upgrade Microsoft access"

    assert has_element?(
             upgrade_view,
             ~s|a[href*="account_id=#{upgrade_account.id}&purpose=send"]|,
             "Continue with Microsoft"
           )

    assert_safe_oauth_html(upgrade_html, [upgrade_authorization.id])

    {:ok, upgrade_show_view, upgrade_show_html} =
      live(conn, ~p"/settings/accounts/#{upgrade_account.id}")

    assert has_element?(
             upgrade_show_view,
             ~s|#upgrade-microsoft-access[href="/connectors/microsoft/start?account_id=#{upgrade_account.id}&purpose=send"]|,
             "Upgrade Microsoft access"
           )

    assert_safe_oauth_html(upgrade_show_html, [upgrade_authorization.id])

    {:ok, add_account} =
      Accounts.create_account(%{name: "Add", address: "add@microsoft-ui.test"})

    add_authorization = insert_microsoft_authorization!(add_account, microsoft_all_scopes())
    insert_microsoft_receive!(add_account, add_authorization)

    {:ok, add_view, _html} =
      live(conn, ~p"/settings/accounts/#{add_account.id}/send_methods/new")

    add_html = add_view |> element("#send-method-microsoft") |> render_click()
    assert add_html =~ "Add Microsoft Send"
    assert has_element?(add_view, "button[phx-click='add-oauth-method']", "Add Microsoft Send")
    assert_safe_oauth_html(add_html, [add_authorization.id])

    add_view
    |> element("button[phx-click='add-oauth-method']")
    |> render_click()

    assert_redirect(add_view, ~p"/settings/accounts/#{add_account.id}")

    assert [%{kind: "microsoft", enabled: true}] =
             Connectors.list_send_methods_for_account(add_account.id)

    {:ok, connected_account} =
      Accounts.create_account(%{name: "Connected", address: "connected@microsoft-ui.test"})

    connected_authorization =
      insert_microsoft_authorization!(connected_account, microsoft_all_scopes())

    insert_microsoft_send!(connected_account, connected_authorization)

    {:ok, connected_view, _html} =
      live(conn, ~p"/settings/accounts/#{connected_account.id}/send_methods/new")

    connected_html = connected_view |> element("#send-method-microsoft") |> render_click()
    assert connected_html =~ "Microsoft Send connected"
    assert has_element?(connected_view, "button[disabled]", "Connected")
    assert_safe_oauth_html(connected_html, [connected_authorization.id])
  end

  test "send-only Microsoft can add or upgrade Microsoft Receive symmetrically", %{conn: conn} do
    configure_microsoft_provider!()

    {:ok, add_account} =
      Accounts.create_account(%{name: "Add receive", address: "add-receive@microsoft-ui.test"})

    add_authorization = insert_microsoft_authorization!(add_account, microsoft_all_scopes())
    insert_microsoft_send!(add_account, add_authorization)

    {:ok, add_view, _html} =
      live(conn, ~p"/settings/accounts/#{add_account.id}/receive_methods/new")

    add_html =
      add_view
      |> element("button[phx-value-kind='microsoft']")
      |> render_click()

    assert add_html =~ "Add Microsoft Receive"
    assert has_element?(add_view, "button[phx-click='add-oauth-method']", "Add Microsoft Receive")
    assert_safe_oauth_html(add_html, [add_authorization.id])

    add_view
    |> element("button[phx-click='add-oauth-method']")
    |> render_click()

    assert_redirect(add_view, ~p"/settings/accounts/#{add_account.id}")

    assert [%{kind: "microsoft", enabled: true}] =
             Connectors.list_receive_methods_for_account(add_account.id)

    {:ok, upgrade_account} =
      Accounts.create_account(%{
        name: "Upgrade receive",
        address: "upgrade-receive@microsoft-ui.test"
      })

    upgrade_authorization =
      insert_microsoft_authorization!(upgrade_account, [MicrosoftScopes.send()])

    insert_microsoft_send!(upgrade_account, upgrade_authorization)

    {:ok, upgrade_view, _html} =
      live(conn, ~p"/settings/accounts/#{upgrade_account.id}/receive_methods/new")

    upgrade_html =
      upgrade_view
      |> element("button[phx-value-kind='microsoft']")
      |> render_click()

    assert upgrade_html =~ "Upgrade Microsoft access"

    assert has_element?(
             upgrade_view,
             ~s|a[href*="account_id=#{upgrade_account.id}&purpose=receive"]|,
             "Continue with Microsoft"
           )

    assert_safe_oauth_html(upgrade_html, [upgrade_authorization.id])
  end

  test "Microsoft reconnect renders one shared action and explains both directions are paused", %{
    conn: conn
  } do
    configure_microsoft_provider!()

    {:ok, account} =
      Accounts.create_account(%{name: "Reconnect", address: "reconnect@microsoft-ui.test"})

    authorization =
      insert_microsoft_authorization!(account, microsoft_all_scopes(),
        status: "reconnect_required",
        error: "raw-provider-error-body-secret"
      )

    insert_microsoft_receive!(account, authorization,
      status: "reconnect_required",
      enabled: false
    )

    insert_microsoft_send!(account, authorization, status: "reconnect_required", enabled: false)

    {:ok, view, html} = live(conn, ~p"/settings/accounts/#{account.id}")

    assert html =~
             "Reconnect the shared Microsoft authorization; both receive and send are paused."

    assert length(Regex.scan(~r/id="reconnect-microsoft"/, html)) == 1

    assert has_element?(
             view,
             ~s|#reconnect-microsoft[href*="account_id=#{account.id}&purpose=receive"]|,
             "Reconnect Microsoft"
           )

    refute html =~ authorization.id
    refute html =~ "raw-provider-error-body-secret"
    refute html =~ MicrosoftScopes.read()
    refute html =~ MicrosoftScopes.send()

    {:ok, reconnect_view, _html} =
      live(conn, ~p"/settings/accounts/#{account.id}/send_methods/new")

    reconnect_html = reconnect_view |> element("#send-method-microsoft") |> render_click()
    assert reconnect_html =~ "Reconnect Microsoft"

    assert has_element?(
             reconnect_view,
             ~s|a[href="/connectors/microsoft/start?account_id=#{account.id}&purpose=send"]|,
             "Reconnect Microsoft"
           )

    assert_safe_oauth_html(reconnect_html, [authorization.id])
  end

  test "Gmail reconnect follows the method that actually requires reconnect", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Send reconnect", address: "send-reconnect@gmail.test"})

    authorization =
      %OAuthAuthorization{}
      |> OAuthAuthorization.changeset(%{
        account_id: account.id,
        provider: "gmail",
        provider_subject_id: "send-reconnect-subject",
        email_address: "send-reconnect@gmail.test",
        granted_scopes: [GmailScopes.read(), GmailScopes.send()],
        status: "reconnect_required",
        key_version: 1
      })
      |> Repo.insert!()

    receive_method =
      %ReceiveMethod{}
      |> ReceiveMethod.changeset(%{
        account_id: account.id,
        oauth_authorization_id: authorization.id,
        kind: "gmail",
        provider_account_id: "send-reconnect-subject",
        email_address: "send-reconnect@gmail.test",
        status: "disconnected",
        enabled: false,
        sync_enabled: false,
        granted_scopes: [GmailScopes.read()]
      })
      |> Repo.insert!()

    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: account.id,
      oauth_authorization_id: authorization.id,
      kind: "gmail",
      email_address: "send-reconnect@gmail.test",
      status: "reconnect_required",
      enabled: false
    })
    |> Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/settings/accounts/#{account.id}")

    assert has_element?(
             view,
             ~s|#reconnect-gmail[href*="account_id=#{account.id}&purpose=send"]|
           )

    refute has_element?(view, ~s|#reconnect-gmail[href*="purpose=receive"]|)
    assert Repo.get!(ReceiveMethod, receive_method.id).status == "disconnected"
  end

  test "account show cannot enable or disconnect another account's send method", %{conn: conn} do
    {:ok, viewed_account} =
      Accounts.create_account(%{name: "Viewed", address: "viewed@example.test"})

    {:ok, foreign_account} =
      Accounts.create_account(%{name: "Foreign", address: "foreign@example.test"})

    foreign_smtp =
      %SendMethod{}
      |> SendMethod.changeset(%{
        account_id: foreign_account.id,
        kind: "smtp",
        email_address: "foreign@example.test",
        status: "connected",
        enabled: false
      })
      |> Repo.insert!()

    authorization_id = Ecto.UUID.generate()

    {:ok, access_ciphertext} =
      Crypto.encrypt("foreign-access-token", "credential:#{authorization_id}:access")

    {:ok, refresh_ciphertext} =
      Crypto.encrypt("foreign-refresh-token", "credential:#{authorization_id}:refresh")

    authorization =
      %OAuthAuthorization{id: authorization_id}
      |> OAuthAuthorization.changeset(%{
        account_id: foreign_account.id,
        provider: "gmail",
        provider_subject_id: "foreign-subject",
        email_address: "foreign@example.test",
        granted_scopes: [GmailScopes.send()],
        status: "connected",
        key_version: 1,
        access_token_ciphertext: access_ciphertext,
        refresh_token_ciphertext: refresh_ciphertext,
        token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })
      |> Repo.insert!()

    foreign_gmail =
      %SendMethod{}
      |> SendMethod.changeset(%{
        account_id: foreign_account.id,
        oauth_authorization_id: authorization.id,
        kind: "gmail",
        email_address: "foreign@example.test",
        status: "connected",
        enabled: true
      })
      |> Repo.insert!()

    {:ok, view, _html} = live(conn, ~p"/settings/accounts/#{viewed_account.id}")

    render_click(view, "enable-send", %{"id" => foreign_smtp.id})
    refute Repo.get!(SendMethod, foreign_smtp.id).enabled

    render_click(view, "disconnect-send", %{"id" => foreign_gmail.id})

    assert Repo.get!(SendMethod, foreign_gmail.id).status == "connected"
    persisted_authorization = Repo.get!(OAuthAuthorization, authorization.id)
    assert persisted_authorization.status == "connected"
    assert persisted_authorization.access_token_ciphertext == access_ciphertext
    assert persisted_authorization.refresh_token_ciphertext == refresh_ciphertext
  end

  test "accounts index shows created account", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Carol", address: "carol@example.test"})

    {:ok, _view, html} = live(conn, ~p"/settings/accounts")
    assert html =~ "Carol"
    assert html =~ "carol@example.test"
    assert html =~ ~p"/settings/accounts/#{account.id}"
    assert html =~ ~p"/settings/accounts/#{account.id}/edit"
  end

  test "accounts index renders accessible icon-only account actions", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Action account", address: "actions@example.test"})

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")

    assert_icon_action(
      view,
      account.id,
      "edit-account",
      "Edit account",
      "pencil-outline"
    )

    assert_icon_action(
      view,
      account.id,
      "manage-account",
      "Manage account",
      "cog-outline"
    )

    assert_icon_action(
      view,
      account.id,
      "disable-account",
      "Disable account",
      "account-off-outline"
    )

    assert_icon_action(
      view,
      account.id,
      "delete-account",
      "Delete account",
      "delete-outline"
    )

    refute has_element?(view, "#edit-account-#{account.id}", "Edit")
    refute has_element?(view, "#manage-account-#{account.id}", "Manage")
    assert has_element?(view, "#delete-account-#{account.id}[phx-click*='push_focus']")
  end

  test "disable keeps the local account and removes only the disable action", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Disabled account", address: "disabled@example.test"})

    {:ok, method} = Connectors.create_placeholder_receive_method(account.id, "pop3")
    {:ok, view, _html} = live(conn, ~p"/settings/accounts")

    view
    |> element("#disable-account-#{account.id}")
    |> render_click()

    assert has_element?(view, "#account-#{account.id}", "Disabled")
    refute has_element?(view, "#disable-account-#{account.id}")
    assert has_element?(view, "#edit-account-#{account.id}")
    assert has_element?(view, "#manage-account-#{account.id}")
    assert has_element?(view, "#delete-account-#{account.id}")
    assert Accounts.get_account!(account.id).active == false

    assert Enum.any?(
             Connectors.list_receive_methods_for_account(account.id),
             &(&1.id == method.id)
           )

    assert is_nil(socket_assign(view, :refresh_timer))
    assert is_nil(socket_assign(view, :refresh_token))
  end

  test "delete requires the exact fresh address and queues local-only deletion", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Archive Relay", address: "delete@example.test"})

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")

    view
    |> element("#delete-account-#{account.id}")
    |> render_click()

    assert has_element?(
             view,
             "#delete-account-dialog[role='dialog'][aria-modal='true'][aria-labelledby='delete-account-title'][aria-describedby='delete-account-warning']"
           )

    assert has_element?(view, "#delete-account-title", "Delete account?")
    assert has_element?(view, ".account-delete-identity strong", "Archive Relay")
    assert has_element?(view, ".account-delete-identity span", "delete@example.test")

    assert has_element?(
             view,
             "#delete-account-warning",
             "permanently deletes this account's local methods"
           )

    assert has_element?(
             view,
             "#delete-account-warning",
             "Mail and accounts held by the remote provider are not deleted"
           )

    assert {:ok, _updated} =
             Accounts.update_account(account, %{
               name: "Archive Relay",
               address: "renamed@example.test"
             })

    view
    |> form("#delete-account-form", confirmation: "delete@example.test")
    |> render_submit()

    assert has_element?(view, "#delete-account-error[role='alert']", "address does not match")
    assert has_element?(view, ".account-delete-identity strong", "Archive Relay")
    assert has_element?(view, ".account-delete-identity span", "renamed@example.test")
    assert is_nil(Repo.get_by(AccountPurge, mailbox_id: account.id))
    assert purge_jobs_for_mailbox(account.id) == []

    view
    |> form("#delete-account-form", confirmation: "renamed@example.test")
    |> render_change()

    assert has_element?(view, "#confirm-delete-account:not([disabled])")

    view
    |> form("#delete-account-form", confirmation: "renamed@example.test")
    |> render_submit()

    purge = Repo.get_by!(AccountPurge, mailbox_id: account.id)
    assert has_element?(view, "#account-#{account.id} [aria-live='polite']", "Deleting...")
    refute has_element?(view, "#account-#{account.id} .account-actions")
    assert render(view) =~ "Account deletion queued."
    assert [%Oban.Job{}] = purge_jobs(purge.id)
    assert is_reference(socket_assign(view, :refresh_timer))
    assert is_reference(socket_assign(view, :refresh_token))
  end

  test "delete dialog traps focus and closes on Escape", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Keyboard delete", address: "keyboard@example.test"})

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")

    view
    |> element("#delete-account-#{account.id}")
    |> render_click()

    assert has_element?(
             view,
             "#delete-account-dialog[phx-hook='Phoenix.FocusWrap'][phx-window-keydown='cancel-delete-account'][phx-key='Escape'][phx-mounted*='focus'][phx-mounted*='delete-account-confirmation'][phx-remove*='pop_focus']"
           )

    assert has_element?(
             view,
             "#delete-account-dialog-start[tabindex='0'][aria-hidden='true']"
           )

    assert has_element?(
             view,
             "#delete-account-dialog-end[tabindex='0'][aria-hidden='true']"
           )

    assert has_element?(view, "#delete-account-dialog #delete-account-confirmation")

    view
    |> element("#delete-account-dialog")
    |> render_keydown(%{"key" => "Escape"})

    refute has_element?(view, "#delete-account-dialog")
    assert has_element?(view, "#delete-account-#{account.id}")
    assert is_nil(Repo.get_by(AccountPurge, mailbox_id: account.id))
  end

  test "stale retry reloads requested state and starts polling", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Stale retry", address: "stale-retry@example.test"})

    {:ok, purge} =
      Manifold.AccountLifecycle.request_deletion(account.id, "stale-retry@example.test")

    discard_purge_jobs(purge.id)

    purge
    |> AccountPurge.changeset(%{status: "failed"})
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")
    assert has_element?(view, "#retry-delete-account-#{account.id}")
    assert is_nil(socket_assign(view, :refresh_timer))
    assert is_nil(socket_assign(view, :refresh_token))

    assert {:ok, _requested} = Manifold.AccountLifecycle.retry_deletion(purge.id)

    view
    |> element("#retry-delete-account-#{account.id}")
    |> render_click()

    assert has_element?(view, "#account-#{account.id} [aria-live='polite']", "Deleting...")
    assert is_reference(socket_assign(view, :refresh_timer))
    assert is_reference(socket_assign(view, :refresh_token))
  end

  test "event reload cancels polling when no account is deleting", %{conn: conn} do
    {:ok, deleting_account} =
      Accounts.create_account(%{name: "Deleting", address: "deleting@example.test"})

    {:ok, active_account} =
      Accounts.create_account(%{name: "Still active", address: "active@example.test"})

    {:ok, purge} =
      Manifold.AccountLifecycle.request_deletion(
        deleting_account.id,
        "deleting@example.test"
      )

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")
    timer = socket_assign(view, :refresh_timer)
    token = socket_assign(view, :refresh_token)
    assert is_reference(timer)
    assert is_reference(token)

    discard_purge_jobs(purge.id)

    purge
    |> AccountPurge.changeset(%{status: "failed"})
    |> Repo.update!()

    view
    |> element("#disable-account-#{active_account.id}")
    |> render_click()

    assert has_element?(view, "#account-#{deleting_account.id}", "Delete failed")
    assert is_nil(socket_assign(view, :refresh_timer))
    assert is_nil(socket_assign(view, :refresh_token))
    assert Process.read_timer(timer) == false

    purge
    |> AccountPurge.changeset(%{status: "requested"})
    |> Repo.update!()

    send(view.pid, {:refresh_accounts, token})

    assert has_element?(view, "#account-#{deleting_account.id}", "Delete failed")
    assert is_nil(socket_assign(view, :refresh_timer))
    assert is_nil(socket_assign(view, :refresh_token))
  end

  test "failed deletion exposes an accessible retry action without polling", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Failed account", address: "failed@example.test"})

    {:ok, purge} =
      Manifold.AccountLifecycle.request_deletion(account.id, "failed@example.test")

    discard_purge_jobs(purge.id)

    purge
    |> AccountPurge.changeset(%{
      status: "failed",
      error_class: "temporary",
      error_code: "storage_unavailable",
      error_message: "Local cleanup could not finish"
    })
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")

    assert has_element?(view, "#account-#{account.id}", "Delete failed")

    assert_icon_action(
      view,
      account.id,
      "retry-delete-account",
      "Retry account deletion",
      "restart"
    )

    assert is_nil(socket_assign(view, :refresh_timer))
    assert is_nil(socket_assign(view, :refresh_token))

    view
    |> element("#retry-delete-account-#{account.id}")
    |> render_click()

    assert has_element?(view, "#account-#{account.id} [aria-live='polite']", "Deleting...")
    refute has_element?(view, "#retry-delete-account-#{account.id}")
    assert is_reference(socket_assign(view, :refresh_timer))
    assert is_reference(socket_assign(view, :refresh_token))
  end

  test "refresh removes an account row after purge completion deletes the mailbox", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Gone account", address: "gone@example.test"})

    assert {:ok, _purge} =
             Manifold.AccountLifecycle.request_deletion(account.id, "gone@example.test")

    {:ok, view, _html} = live(conn, ~p"/settings/accounts")
    assert has_element?(view, "#account-#{account.id}")
    token = socket_assign(view, :refresh_token)
    assert is_reference(token)

    Repo.delete!(Accounts.get_account!(account.id))
    send(view.pid, {:refresh_accounts, token})

    refute has_element?(view, "#account-#{account.id}")
    assert is_nil(socket_assign(view, :refresh_timer))
    assert is_nil(socket_assign(view, :refresh_token))
  end

  test "accounts index and show render settings nav with Accounts current", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Nav", address: "nav@example.test"})

    {:ok, _view, html} = live(conn, ~p"/settings/accounts")
    assert html =~ ~s(id="settings-nav")
    assert html =~ ~s(data-current="accounts")

    {:ok, _view, html} = live(conn, ~p"/settings/accounts/#{account.id}")
    assert html =~ ~s(id="settings-nav")
    assert html =~ ~s(data-current="accounts")
  end

  test "edit account updates name and address", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Dana", address: "dana@example.test"})

    {:ok, view, html} = live(conn, ~p"/settings/accounts/#{account.id}/edit")
    assert html =~ "dana@example.test"

    {:ok, _show_view, html} =
      view
      |> form("#account-form", account: %{name: "Danielle", address: "danielle@example.test"})
      |> render_submit()
      |> follow_redirect(conn)

    assert html =~ "Danielle"
    assert html =~ "danielle@example.test"

    updated = Accounts.get_account!(account.id)
    assert updated.name == "Danielle"
    assert Accounts.account_address(updated) == "danielle@example.test"
  end

  defp configure_microsoft_provider! do
    previous_key = Application.get_env(:manifold_connectors, :encryption_key)
    previous_adapters = Application.get_env(:manifold_connectors, :adapters)
    previous_providers = Application.get_env(:manifold_connectors, :providers)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(
      :manifold_connectors,
      :adapters,
      Keyword.put(previous_adapters || [], :microsoft, MicrosoftSetupProvider)
    )

    Application.put_env(
      :manifold_connectors,
      :providers,
      Keyword.put(previous_providers || [], :microsoft,
        client_id: "microsoft-client-id",
        client_secret: "microsoft-client-secret",
        authorization_url: "https://login.microsoft.test/authorize"
      )
    )

    on_exit(fn ->
      restore_smtp_env(:encryption_key, previous_key)
      restore_smtp_env(:adapters, previous_adapters)
      restore_smtp_env(:providers, previous_providers)
    end)
  end

  defp insert_microsoft_authorization!(account, scopes, opts \\ []) do
    authorization_id = Ecto.UUID.generate()

    {:ok, access_ciphertext} =
      Crypto.encrypt(
        "microsoft-access-token-private-sentinel",
        "credential:#{authorization_id}:access"
      )

    {:ok, refresh_ciphertext} =
      Crypto.encrypt(
        "microsoft-refresh-token-private-sentinel",
        "credential:#{authorization_id}:refresh"
      )

    %OAuthAuthorization{id: authorization_id}
    |> OAuthAuthorization.changeset(%{
      account_id: account.id,
      provider: "microsoft",
      provider_subject_id: "subject-#{authorization_id}",
      email_address: Accounts.account_address(account),
      granted_scopes: scopes,
      status: Keyword.get(opts, :status, "connected"),
      key_version: 1,
      access_token_ciphertext: access_ciphertext,
      refresh_token_ciphertext: refresh_ciphertext,
      token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
      last_error_class: if(Keyword.has_key?(opts, :error), do: "reconnect", else: nil),
      last_error_code: if(Keyword.has_key?(opts, :error), do: "invalid_grant", else: nil),
      last_error_message: Keyword.get(opts, :error)
    })
    |> Repo.insert!()
  end

  defp insert_microsoft_receive!(account, authorization, opts \\ []) do
    %ReceiveMethod{}
    |> ReceiveMethod.changeset(%{
      account_id: account.id,
      oauth_authorization_id: authorization.id,
      kind: "microsoft",
      provider_account_id: authorization.provider_subject_id,
      email_address: Accounts.account_address(account),
      status: Keyword.get(opts, :status, "connected"),
      enabled: Keyword.get(opts, :enabled, true),
      sync_enabled: Keyword.get(opts, :enabled, true),
      granted_scopes: authorization.granted_scopes,
      last_error_message: Keyword.get(opts, :error)
    })
    |> Repo.insert!()
  end

  defp insert_microsoft_send!(account, authorization, opts \\ []) do
    %SendMethod{}
    |> SendMethod.changeset(%{
      account_id: account.id,
      oauth_authorization_id: authorization.id,
      kind: "microsoft",
      email_address: Accounts.account_address(account),
      status: Keyword.get(opts, :status, "connected"),
      enabled: Keyword.get(opts, :enabled, true),
      last_error_message: Keyword.get(opts, :error)
    })
    |> Repo.insert!()
  end

  defp microsoft_all_scopes do
    [MicrosoftScopes.read(), MicrosoftScopes.send(), MicrosoftScopes.offline()]
  end

  defp assert_safe_oauth_html(html, secrets) do
    for secret <-
          secrets ++
            [
              MicrosoftScopes.read(),
              MicrosoftScopes.send(),
              MicrosoftScopes.offline(),
              "microsoft-access-token-private-sentinel",
              "microsoft-refresh-token-private-sentinel",
              "raw-provider-error-body-secret"
            ] do
      refute html =~ secret
    end
  end

  defp restore_smtp_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_smtp_env(key, value), do: Application.put_env(:manifold_connectors, key, value)

  defp assert_icon_action(view, account_id, action, label, icon) do
    tooltip_id = "#{action}-tooltip-#{account_id}"
    action_id = "#{action}-#{account_id}"

    assert has_element?(
             view,
             "##{tooltip_id}.tooltip-left[aria-describedby='#{tooltip_id}-tooltip'] ##{action_id}[aria-label='#{label}'] svg[data-icon='#{icon}']"
           )

    assert has_element?(
             view,
             "##{tooltip_id} .tooltip-content[role='tooltip']",
             label
           )
  end

  defp socket_assign(view, key) do
    view.pid
    |> :sys.get_state()
    |> Map.fetch!(:socket)
    |> Map.fetch!(:assigns)
    |> Map.fetch!(key)
  end

  defp purge_jobs_for_mailbox(mailbox_id) do
    case Repo.get_by(AccountPurge, mailbox_id: mailbox_id) do
      nil -> []
      purge -> purge_jobs(purge.id)
    end
  end

  defp purge_jobs(purge_id) do
    PurgeAccount
    |> purge_job_query(purge_id)
    |> Repo.all()
  end

  defp discard_purge_jobs(purge_id) do
    PurgeAccount
    |> purge_job_query(purge_id)
    |> Repo.update_all(set: [state: "discarded"])
  end

  defp purge_job_query(worker, purge_id) do
    from(job in Oban.Job,
      where:
        job.worker == ^inspect(worker) and
          fragment("?->>'purge_id'", job.args) == ^purge_id
    )
  end
end

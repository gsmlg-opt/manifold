defmodule ManifoldWeb.AccountLiveTest do
  use ManifoldWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.GmailScopes
  alias Manifold.Connectors.Schema.{OAuthAuthorization, ReceiveMethod, SendMethod}
  alias Manifold.Repo

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
    previous_providers = Application.get_env(:manifold_connectors, :providers)
    Application.put_env(:manifold_connectors, :providers, [])

    on_exit(fn -> restore_smtp_env(:providers, previous_providers) end)

    {:ok, account} =
      Accounts.create_account(%{name: "No OAuth", address: "no-oauth@example.test"})

    {:ok, view, html} = live(conn, ~p"/settings/accounts/#{account.id}/send_methods/new")

    assert html =~ "Choose send method"
    assert has_element?(view, "#send-method-gmail[disabled]")
    assert has_element?(view, "#send-method-gmail", "Provider not configured")
    assert has_element?(view, "#send-method-smtp")
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

  defp restore_smtp_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_smtp_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

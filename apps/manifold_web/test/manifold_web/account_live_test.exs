defmodule ManifoldWeb.AccountLiveTest do
  use ManifoldWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Manifold.Accounts
  alias Manifold.Connectors

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

  test "accounts index shows created account", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Carol", address: "carol@example.test"})

    {:ok, _view, html} = live(conn, ~p"/settings/accounts")
    assert html =~ "Carol"
    assert html =~ "carol@example.test"
    assert html =~ ~p"/settings/accounts/#{account.id}"
    assert html =~ ~p"/settings/accounts/#{account.id}/edit"
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

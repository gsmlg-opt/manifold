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

  test "account show lists receive methods and allows placeholder", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Bob", address: "bob@example.test"})

    {:ok, view, html} = live(conn, ~p"/settings/accounts/#{account.id}")
    assert html =~ "bob@example.test"

    view |> element("#add-receive-method") |> render_click()
    view |> element("button", "POP3") |> render_click()

    html = render(view)
    assert html =~ "POP3"
    assert html =~ "Not_implemented"

    methods = Connectors.list_receive_methods_for_account(account.id)
    assert length(methods) == 1
    assert hd(methods).kind == "pop3"
    refute hd(methods).enabled
  end

  test "accounts index shows created account", %{conn: conn} do
    {:ok, account} =
      Accounts.create_account(%{name: "Carol", address: "carol@example.test"})

    {:ok, _view, html} = live(conn, ~p"/settings/accounts")
    assert html =~ "Carol"
    assert html =~ "carol@example.test"
    assert html =~ ~p"/settings/accounts/#{account.id}"
  end
end

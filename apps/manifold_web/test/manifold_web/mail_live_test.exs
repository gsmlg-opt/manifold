defmodule ManifoldWeb.MailLiveTest do
  use ManifoldWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "empty state primary cta goes to add account", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ ~p"/settings/accounts/new"
    assert html =~ "Add account"
    assert html =~ "Connect an email account"
    assert html =~ ~p"/settings/accounts"
  end
end

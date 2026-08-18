defmodule ManifoldWeb.SettingsLiveTest do
  use ManifoldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "GET /settings redirects to /settings/general", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    assert redirected_to(conn) == ~p"/settings/general"
  end

  test "general settings page renders placeholder", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/general")
    assert html =~ "General"
    assert html =~ "Coming soon"
  end

  test "general settings page renders left nav with General current", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/general")

    assert html =~ ~s(id="settings-nav")
    assert html =~ ~p"/settings/general"
    assert html =~ ~p"/settings/accounts"
    assert html =~ "/settings/oauth"
    assert html =~ ~p"/settings/appearance"
    assert html =~ ~s(data-current="general")
  end

  test "appearance settings page renders placeholder with Appearance current", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/appearance")

    assert html =~ "Appearance"
    assert html =~ "Coming soon"
    assert html =~ ~s(id="settings-nav")
    assert html =~ "/settings/oauth"
    assert html =~ ~s(data-current="appearance")
  end

  test "accounts settings page renders OAuth navigation with Accounts current", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/accounts")

    assert html =~ "/settings/oauth"
    assert html =~ ~s(data-current="accounts")
  end

  test "appbar Settings menu points at /settings", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/general")
    assert html =~ ~s(href="/settings")
  end
end

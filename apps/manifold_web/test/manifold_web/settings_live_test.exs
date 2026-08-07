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
end

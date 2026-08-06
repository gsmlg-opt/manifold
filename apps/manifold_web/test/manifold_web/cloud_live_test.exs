defmodule ManifoldWeb.CloudLiveTest do
  use ManifoldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "local operator can view cloud ingress status without secret material", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/cloud")

    assert html =~ "Cloud Ingress"
    assert html =~ "Not configured"
    assert html =~ ~s(id="app-theme-switcher")
    assert html =~ "theme-controller-dropdown"
    assert html =~ "appbar-primary"
    refute html =~ "shared_secret"
    refute html =~ "spool_bundle_path"
  end
end

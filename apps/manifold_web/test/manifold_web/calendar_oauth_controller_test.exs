defmodule ManifoldWeb.CalendarOAuthControllerTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Connectors.{CalendarConnections, ProviderSettings}
  alias Manifold.Connectors.Schema.CalendarOAuthTransaction
  alias Manifold.Repo

  test "an unrelated Gmail callback preserves a pending Calendar session", %{conn: conn} do
    conn = conn |> init_test_session(%{calendar_oauth_state: "pending-calendar-state"})

    conn =
      get(conn, "/connectors/gmail/callback", %{
        state: "unrelated-mail-state",
        error: "access_denied"
      })

    assert redirected_to(conn) == "/settings/accounts"
    assert Plug.Conn.get_session(conn, :calendar_oauth_state) == "pending-calendar-state"
  end

  test "matching shared callback consumes Calendar state once even when denied", %{conn: conn} do
    {:ok, _} =
      ProviderSettings.put("gmail", %{client_id: "calendar-client", client_secret: "secret"})

    {:ok, started} =
      CalendarConnections.start_google_authorization(
        redirect_uri: "http://localhost/connectors/gmail/callback"
      )

    conn = conn |> init_test_session(%{calendar_oauth_state: started.state})

    conn =
      get(conn, "/connectors/gmail/callback", %{state: started.state, error: "access_denied"})

    assert redirected_to(conn) == "/calendars"
    assert Plug.Conn.get_session(conn, :calendar_oauth_state) == nil
    assert [%{consumed_at: %DateTime{}}] = Repo.all(CalendarOAuthTransaction)

    conn =
      conn
      |> recycle()
      |> get("/connectors/gmail/callback", %{state: started.state, error: "access_denied"})

    assert redirected_to(conn) == "/settings/accounts"
  end
end

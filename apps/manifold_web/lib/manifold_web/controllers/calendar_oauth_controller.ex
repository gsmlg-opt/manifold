defmodule ManifoldWeb.CalendarOAuthController do
  use ManifoldWeb, :controller
  alias Manifold.Connectors.{CalendarConnections, ProviderConfig}

  def start(conn, _params) do
    with {:ok, redirect_uri} <-
           ProviderConfig.callback_url("gmail", url(~p"/calendar-connections/google/callback")),
         {:ok, authorization} <-
           CalendarConnections.start_google_authorization(redirect_uri: redirect_uri) do
      conn
      |> put_session(:calendar_oauth_state, authorization.state)
      |> redirect(external: authorization.url)
    else
      _ ->
        conn
        |> put_flash(:error, "Configure Google OAuth in Settings before connecting a calendar.")
        |> redirect(to: ~p"/calendars")
    end
  end

  def callback(conn, params) do
    expected = get_session(conn, :calendar_oauth_state)
    conn = delete_session(conn, :calendar_oauth_state)

    case CalendarConnections.complete_google_authorization(params, expected_state: expected) do
      {:ok, _} ->
        conn
        |> put_flash(
          :info,
          "Google Calendar connected. Choose a local calendar and preview its sync targets."
        )
        |> redirect(to: ~p"/calendars")

      {:error, _} ->
        conn
        |> put_flash(
          :error,
          "Calendar authorization failed or expired. Start the connection again."
        )
        |> redirect(to: ~p"/calendars")
    end
  end
end

defmodule ManifoldWeb.SettingsRedirectController do
  use ManifoldWeb, :controller

  def redirect_general(conn, _params) do
    redirect(conn, to: ~p"/settings/general")
  end
end

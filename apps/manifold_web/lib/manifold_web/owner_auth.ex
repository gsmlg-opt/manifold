defmodule ManifoldWeb.OwnerAuth do
  @moduledoc false

  import Phoenix.Controller
  import Plug.Conn

  alias Manifold.Accounts

  def fetch_current_owner(conn, _opts) do
    owner_id = get_session(conn, :owner_id)
    owner = owner_id && Accounts.get_owner!(owner_id)
    assign(conn, :current_owner, owner)
  rescue
    Ecto.NoResultsError -> assign(conn, :current_owner, nil)
  end

  def log_in_owner(conn, owner) do
    conn
    |> configure_session(renew: true)
    |> put_session(:owner_id, owner.id)
  end

  def log_out_owner(conn) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket =
      Phoenix.Component.assign_new(socket, :current_owner, fn ->
        with owner_id when is_binary(owner_id) <- session["owner_id"] do
          Accounts.get_owner!(owner_id)
        end
      end)

    if socket.assigns.current_owner do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
    end
  rescue
    Ecto.NoResultsError ->
      {:halt, Phoenix.LiveView.redirect(socket, to: "/login")}
  end
end

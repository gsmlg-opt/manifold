defmodule ManifoldWeb.ConnectorOAuthController do
  use ManifoldWeb, :controller

  alias Manifold.Connectors
  alias Manifold.Connectors.OAuth

  # Gmail keeps authorization-code + PKCE because Google's device-flow allowlist
  # excludes Gmail API scopes. Microsoft uses device flow in LiveView instead.
  @gmail "gmail"

  def start(conn, %{"provider" => @gmail, "mailbox_id" => mailbox_id}) do
    case OAuth.start(@gmail, mailbox_id, callback_url(@gmail)) do
      {:ok, authorization} ->
        redirect(conn, external: authorization.url)

      {:error, _reason} ->
        connector_error(conn, "The Gmail connection could not be started.")
    end
  end

  def start(conn, %{"provider" => "microsoft"}) do
    connector_error(
      conn,
      "Microsoft 365 uses device authorization. Start the connection from Add account."
    )
  end

  def start(conn, _params) do
    connector_error(conn, "The external account connection could not be started.")
  end

  def callback(conn, %{"provider" => @gmail, "code" => code, "state" => state}) do
    redirect_uri = callback_url(@gmail)

    case OAuth.consume(@gmail, state, redirect_uri) do
      {:ok, consumed} ->
        complete_authorization(conn, code, consumed)

      {:error, _reason} ->
        connector_error(conn, "The Gmail authorization request is invalid or expired.")
    end
  end

  def callback(conn, %{"provider" => @gmail}) do
    connector_error(conn, "The Gmail authorization request is invalid or expired.")
  end

  def callback(conn, %{"provider" => "microsoft"}) do
    connector_error(
      conn,
      "Microsoft 365 uses device authorization. Start the connection from Add account."
    )
  end

  def callback(conn, _params) do
    connector_error(conn, "The external account authorization request is invalid or expired.")
  end

  defp complete_authorization(conn, code, consumed) do
    case Connectors.complete_authorization(@gmail, code, consumed) do
      {:ok, _account} ->
        conn
        |> put_flash(:info, "Gmail account connected.")
        |> redirect(to: ~p"/settings/accounts")

      {:error, _reason} ->
        connector_error(conn, "The Gmail account could not be connected.")
    end
  end

  defp connector_error(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/settings/accounts")
  end

  defp callback_url(provider), do: url(~p"/connectors/#{provider}/callback")
end

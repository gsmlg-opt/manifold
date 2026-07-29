defmodule ManifoldWeb.ConnectorOAuthController do
  use ManifoldWeb, :controller

  alias Manifold.Connectors
  alias Manifold.Connectors.OAuth

  @providers ~w(gmail microsoft)

  def start(conn, %{"provider" => provider, "mailbox_id" => mailbox_id})
      when provider in @providers do
    case OAuth.start(provider, mailbox_id, callback_url(provider)) do
      {:ok, authorization} ->
        redirect(conn, external: authorization.url)

      {:error, _reason} ->
        connector_error(conn, "The #{provider_name(provider)} connection could not be started.")
    end
  end

  def start(conn, _params) do
    connector_error(conn, "The external account connection could not be started.")
  end

  def callback(conn, %{"provider" => provider, "code" => code, "state" => state})
      when provider in @providers do
    redirect_uri = callback_url(provider)

    case OAuth.consume(provider, state, redirect_uri) do
      {:ok, consumed} ->
        complete_authorization(conn, provider, code, consumed)

      {:error, _reason} ->
        connector_error(
          conn,
          "The #{provider_name(provider)} authorization request is invalid or expired."
        )
    end
  end

  def callback(conn, %{"provider" => provider}) when provider in @providers do
    connector_error(
      conn,
      "The #{provider_name(provider)} authorization request is invalid or expired."
    )
  end

  def callback(conn, _params) do
    connector_error(conn, "The external account authorization request is invalid or expired.")
  end

  defp complete_authorization(conn, provider, code, consumed) do
    case Connectors.complete_authorization(provider, code, consumed) do
      {:ok, _account} ->
        conn
        |> put_flash(:info, "#{provider_name(provider)} account connected.")
        |> redirect(to: ~p"/settings/accounts")

      {:error, _reason} ->
        connector_error(conn, "The #{provider_name(provider)} account could not be connected.")
    end
  end

  defp connector_error(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/settings/accounts")
  end

  defp callback_url(provider), do: url(~p"/connectors/#{provider}/callback")

  defp provider_name("gmail"), do: "Gmail"
  defp provider_name("microsoft"), do: "Microsoft 365"
end

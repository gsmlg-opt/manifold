defmodule ManifoldWeb.ConnectorOAuthController do
  use ManifoldWeb, :controller

  alias Manifold.Connectors
  alias Manifold.Connectors.OAuth

  @providers ~w(gmail microsoft)

  def start(conn, %{"provider" => provider} = params) when provider in @providers do
    account_id = Map.get(params, "account_id") || Map.get(params, "mailbox_id")

    with true <- is_binary(account_id) and account_id != "",
         {:ok, purpose} <- purpose(params) do
      case OAuth.start(provider, account_id, callback_url(provider), purpose: purpose) do
        {:ok, authorization} ->
          redirect(conn, external: authorization.url)

        {:error, _reason} ->
          connector_error(conn, "The #{provider_name(provider)} connection could not be started.")
      end
    else
      _invalid -> connector_error(conn, "The account connection could not be started.")
    end
  end

  def start(conn, _params) do
    connector_error(conn, "The account connection could not be started.")
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
    connector_error(conn, "The account authorization request is invalid or expired.")
  end

  defp complete_authorization(conn, provider, code, consumed) do
    case Connectors.complete_authorization(provider, code, consumed) do
      {:ok, _method} ->
        conn
        |> put_flash(
          :info,
          "#{provider_name(provider)} #{purpose_name(consumed.purpose)} method connected."
        )
        |> redirect(to: ~p"/settings/accounts/#{consumed.mailbox_id}")

      {:error, _reason} ->
        connector_error(
          conn,
          "The #{provider_name(provider)} account could not be connected.",
          consumed.mailbox_id
        )
    end
  end

  defp connector_error(conn, message, account_id \\ nil) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: error_path(account_id))
  end

  defp purpose(%{"purpose" => "receive"}), do: {:ok, :receive}
  defp purpose(%{"purpose" => "send"}), do: {:ok, :send}
  defp purpose(params) when not is_map_key(params, "purpose"), do: {:ok, :receive}
  defp purpose(_params), do: :error

  defp purpose_name(:receive), do: "receive"
  defp purpose_name(:send), do: "send"

  defp error_path(nil), do: ~p"/settings/accounts"
  defp error_path(account_id), do: ~p"/settings/accounts/#{account_id}"

  defp callback_url(provider), do: url(~p"/connectors/#{provider}/callback")

  defp provider_name("gmail"), do: "Gmail"
  defp provider_name("microsoft"), do: "Microsoft 365"
end

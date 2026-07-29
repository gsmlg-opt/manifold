defmodule ManifoldWeb.ResendWebhookController do
  use ManifoldWeb, :controller

  alias Manifold.Core.Error
  alias Manifold.Outbound
  alias Manifold.Outbound.Provider
  alias Manifold.Outbound.Provider.Resend

  @signature_headers ~w(svix-id svix-timestamp svix-signature)

  def create(conn, _params) do
    raw_body = Map.get(conn.assigns, :raw_body, "")
    config = Application.get_env(:manifold_outbound, :provider_config, [])

    record_options =
      Application.get_env(:manifold_web, :resend_webhook_record_options, [])

    with {:ok, event} <- Resend.verify_webhook(config, signature_headers(conn), raw_body),
         {:ok, _outcome} <- Outbound.record_provider_event("resend", event, record_options) do
      send_resp(conn, 200, "")
    else
      {:error, %Provider.Error{}} ->
        send_resp(conn, 400, "Invalid webhook")

      {:error, %Error{class: :temporary}} ->
        send_resp(conn, 503, "Webhook persistence temporarily unavailable")

      {:error, %Ecto.Changeset{}} ->
        send_resp(conn, 503, "Webhook persistence temporarily unavailable")
    end
  end

  defp signature_headers(conn) do
    Map.new(@signature_headers, fn name ->
      {name, conn |> get_req_header(name) |> Enum.join(" ")}
    end)
  end
end

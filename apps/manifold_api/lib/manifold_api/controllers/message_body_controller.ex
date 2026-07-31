defmodule ManifoldAPI.MessageBodyController do
  use ManifoldAPI, :controller

  action_fallback(ManifoldAPI.FallbackController)

  alias ManifoldAPI.Mail

  def show(conn, %{"mailbox_id" => mailbox_id, "message_id" => message_id}) do
    with {:ok, body} <- Mail.get_message_body(mailbox_id, message_id) do
      json(conn, body)
    end
  end
end

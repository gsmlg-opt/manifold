defmodule ManifoldWeb.SentRedirectController do
  use ManifoldWeb, :controller

  alias Manifold.Accounts
  alias Manifold.Mail

  def index(conn, %{"mailbox_id" => mailbox_id_param}) do
    with {:ok, mailbox_id} <- Ecto.UUID.cast(mailbox_id_param),
         %{} <- Accounts.get_account(mailbox_id),
         {:ok, folders} <- Mail.list_folders(mailbox_id),
         %{} = sent <- Enum.find(folders, &(&1.kind == "sent")) do
      redirect(conn, to: ~p"/mail/#{mailbox_id}/folders/#{sent.id}")
    else
      _unavailable -> unavailable(conn)
    end
  end

  def show(conn, %{
        "mailbox_id" => mailbox_id_param,
        "outbound_message_id" => message_id_param
      }) do
    with {:ok, mailbox_id} <- Ecto.UUID.cast(mailbox_id_param),
         {:ok, message_id} <- Ecto.UUID.cast(message_id_param) do
      redirect(conn, to: ~p"/mail/#{mailbox_id}/send-activity/#{message_id}")
    else
      :error -> unavailable(conn)
    end
  end

  defp unavailable(conn) do
    conn
    |> put_flash(:error, "The requested mailbox view is unavailable.")
    |> redirect(to: ~p"/")
  end
end

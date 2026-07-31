defmodule ManifoldAPI.FolderController do
  use ManifoldAPI, :controller

  action_fallback(ManifoldAPI.FallbackController)

  alias ManifoldAPI.Mail

  def index(conn, %{"mailbox_id" => mailbox_id}) do
    with {:ok, folders} <- Mail.list_folders(mailbox_id) do
      json(conn, %{data: folders})
    end
  end
end

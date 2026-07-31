defmodule ManifoldAPI.ConversationController do
  use ManifoldAPI, :controller

  action_fallback(ManifoldAPI.FallbackController)

  alias ManifoldAPI.Mail

  def index(conn, %{"mailbox_id" => mailbox_id, "folder_id" => folder_id} = params) do
    opts = [
      after: params["after"],
      limit: params["limit"],
      q: params["q"]
    ]

    with {:ok, page} <- Mail.list_conversations(mailbox_id, folder_id, opts) do
      json(conn, page)
    end
  end

  def search(conn, %{"mailbox_id" => mailbox_id} = params) do
    query = params["q"] || ""

    opts = [
      after: params["after"],
      limit: params["limit"]
    ]

    with {:ok, page} <- Mail.search(mailbox_id, query, opts) do
      json(conn, page)
    end
  end

  def show(conn, %{"mailbox_id" => mailbox_id, "thread_id" => thread_id}) do
    with {:ok, conversation} <- Mail.get_conversation(mailbox_id, thread_id) do
      json(conn, conversation)
    end
  end
end

defmodule ManifoldAPI.MailboxController do
  use ManifoldAPI, :controller

  action_fallback(ManifoldAPI.FallbackController)

  alias ManifoldAPI.Mail

  def index(conn, _params) do
    with {:ok, mailboxes} <- Mail.list_mailboxes() do
      json(conn, %{data: mailboxes})
    end
  end
end

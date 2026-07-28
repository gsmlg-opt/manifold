defmodule ManifoldWeb.MailboxLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Mailboxes", mailboxes: Accounts.list_mailboxes())}
  end

  def render(assigns) do
    ~H"""
    <section>
      <h1>Mailboxes</h1>
      <table>
        <thead>
          <tr>
            <th>Mailbox</th><th>Name</th><th>Active</th><th>Plus Addressing</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={mailbox <- @mailboxes}>
            <td>{mailbox.local_part}@{mailbox.domain.normalized_domain}</td>
            <td>{mailbox.display_name}</td>
            <td>{yes_no(mailbox.active)}</td>
            <td>{yes_no(mailbox.plus_addressing_enabled)}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
end

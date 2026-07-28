defmodule ManifoldWeb.AliasLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Aliases", aliases: Accounts.list_aliases())}
  end

  def render(assigns) do
    ~H"""
    <section>
      <h1>Aliases</h1>
      <table>
        <thead>
          <tr>
            <th>Alias</th><th>Active</th><th>Plus Addressing</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={alias <- @aliases}>
            <td>{alias.local_part}@{alias.domain.normalized_domain}</td>
            <td>{yes_no(alias.active)}</td>
            <td>{yes_no(alias.plus_addressing_enabled)}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
end

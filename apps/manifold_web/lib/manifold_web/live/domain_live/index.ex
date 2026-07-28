defmodule ManifoldWeb.DomainLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts

  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Domains", domains: Accounts.list_domains())}
  end

  def render(assigns) do
    ~H"""
    <section>
      <h1>Domains</h1>
      <table>
        <thead>
          <tr>
            <th>Domain</th><th>Active</th><th>Plus Addressing</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={domain <- @domains}>
            <td>{domain.normalized_domain}</td>
            <td>{yes_no(domain.active)}</td>
            <td>{yes_no(domain.plus_addressing_enabled)}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
end

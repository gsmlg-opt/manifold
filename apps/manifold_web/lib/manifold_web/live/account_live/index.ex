defmodule ManifoldWeb.AccountLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts
  alias Manifold.Connectors

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    accounts =
      Accounts.list_accounts()
      |> Enum.map(fn account ->
        methods = Connectors.list_receive_methods_for_account(account.id)
        enabled = Enum.find(methods, & &1.enabled)

        %{
          account: account,
          address: Accounts.account_address(account),
          methods: methods,
          enabled_method: enabled
        }
      end)

    {:ok, assign(socket, page_title: "Accounts", accounts: accounts)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>Accounts</h1>
          <p class="settings-intro">
            Local email identities and their receive methods.
          </p>
        </div>
        <div class="settings-heading-actions">
          <.link
            id="add-account-button"
            navigate={~p"/settings/accounts/new"}
            class="settings-action settings-action-primary"
          >
            <.dm_mdi name="plus" /> Add account
          </.link>
        </div>
      </div>

      <div class="table-scroll">
        <table id="accounts">
          <thead>
            <tr>
              <th>Name</th>
              <th>Address</th>
              <th>Active receive method</th>
              <th>Methods</th>
              <th><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @accounts} id={"account-#{row.account.id}"}>
              <td data-label="Name">
                <strong>{row.account.name || row.account.local_part}</strong>
              </td>
              <td data-label="Address">{row.address}</td>
              <td data-label="Active receive method">
                <span :if={row.enabled_method}>
                  {kind_label(row.enabled_method.kind)}
                  <span class={"policy-state state-#{row.enabled_method.status}"}>
                    {String.capitalize(row.enabled_method.status)}
                  </span>
                </span>
                <span :if={!row.enabled_method} class="settings-secondary">None</span>
              </td>
              <td data-label="Methods">{length(row.methods)}</td>
              <td data-label="Actions">
                <div class="account-actions">
                  <.link
                    navigate={~p"/settings/accounts/#{row.account.id}/edit"}
                    class="settings-action"
                  >
                    Edit
                  </.link>
                  <.link
                    navigate={~p"/settings/accounts/#{row.account.id}"}
                    class="settings-action"
                  >
                    Manage
                  </.link>
                </div>
              </td>
            </tr>
            <tr :if={@accounts == []}>
              <td colspan="5" class="settings-empty">No accounts yet.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp kind_label("gmail"), do: "Gmail"
  defp kind_label("microsoft"), do: "Microsoft Graph"
  defp kind_label("imap"), do: "IMAP"
  defp kind_label("pop3"), do: "POP3"
  defp kind_label("eas"), do: "EAS"
  defp kind_label("ews"), do: "EWS"
  defp kind_label(kind), do: kind
end

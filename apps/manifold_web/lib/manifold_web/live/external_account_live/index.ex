defmodule ManifoldWeb.ExternalAccountLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts
  alias Manifold.Connectors

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "External accounts",
       mailboxes: Accounts.list_active_mailboxes(),
       accounts: Connectors.list_accounts(),
       configured_providers: Connectors.configured_providers()
     )}
  end

  @impl Phoenix.LiveView
  def handle_event("sync", %{"id" => account_id}, socket) do
    case Connectors.enqueue_sync(account_id) do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :info, "Synchronization queued.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Synchronization could not be queued.")}
    end
  end

  def handle_event("disconnect", %{"id" => account_id}, socket) do
    case Connectors.disconnect(account_id) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> assign(:accounts, Connectors.list_accounts())
         |> put_flash(:info, "External account disconnected.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "External account could not be disconnected.")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <h1>External accounts</h1>
        <nav class="settings-nav" aria-label="Settings">
          <.link navigate={~p"/mailboxes"}>Mailboxes</.link>
          <.link navigate={~p"/domains"}>Domains</.link>
          <.link navigate={~p"/aliases"}>Aliases</.link>
        </nav>
      </div>

      <h2>Local mailboxes</h2>
      <div class="table-scroll">
        <table id="connector-mailboxes">
          <thead>
            <tr>
              <th>Mailbox</th>
              <th>Connect provider</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={mailbox <- @mailboxes}>
              <td>
                <strong>{mailbox_address(mailbox)}</strong>
                <span :if={mailbox.display_name} class="settings-secondary">
                  {mailbox.display_name}
                </span>
              </td>
              <td>
                <div class="provider-actions">
                  <a
                    :if={"gmail" in @configured_providers}
                    class="settings-action"
                    href={~p"/connectors/gmail/start?#{[mailbox_id: mailbox.id]}"}
                  >
                    <.dm_mdi name="gmail" /> Connect Gmail
                  </a>
                  <a
                    :if={"microsoft" in @configured_providers}
                    class="settings-action"
                    href={~p"/connectors/microsoft/start?#{[mailbox_id: mailbox.id]}"}
                  >
                    <.dm_mdi name="microsoft" /> Connect Microsoft 365
                  </a>
                  <span :if={@configured_providers == []} class="settings-secondary">
                    No provider is configured
                  </span>
                </div>
              </td>
            </tr>
            <tr :if={@mailboxes == []}>
              <td colspan="2" class="settings-empty">No local mailboxes.</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2>Connected accounts</h2>
      <div class="table-scroll">
        <table id="external-accounts">
          <thead>
            <tr>
              <th>Provider account</th>
              <th>Local mailbox</th>
              <th>Status</th>
              <th>Last synchronized</th>
              <th><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={account <- @accounts} id={"external-account-#{account.id}"}>
              <td data-label="Provider account">
                <strong>{provider_name(account.provider)}</strong>
                <span class="settings-secondary">{account.email_address}</span>
              </td>
              <td data-label="Local mailbox">{mailbox_address(account.mailbox_id, @mailboxes)}</td>
              <td data-label="Status">
                <span class={"policy-state state-#{account.status}"}>
                  {status_label(account.status)}
                </span>
                <span :if={account.last_error} class="settings-error">
                  {account.last_error}
                </span>
              </td>
              <td data-label="Last synchronized">{format_datetime(account.last_synced_at)}</td>
              <td data-label="Actions">
                <div class="account-actions">
                  <button
                    type="button"
                    class="settings-icon-button"
                    phx-click="sync"
                    phx-value-id={account.id}
                    disabled={!account.sync_enabled}
                    title="Synchronize now"
                    aria-label={"Synchronize #{account.email_address}"}
                  >
                    <.dm_mdi name="sync" />
                  </button>
                  <button
                    type="button"
                    class="settings-icon-button settings-icon-button-danger"
                    phx-click="disconnect"
                    phx-value-id={account.id}
                    disabled={account.status == "disconnected"}
                    data-confirm="Disconnect this external account?"
                    title="Disconnect account"
                    aria-label={"Disconnect #{account.email_address}"}
                  >
                    <.dm_mdi name="link-off" />
                  </button>
                </div>
              </td>
            </tr>
            <tr :if={@accounts == []}>
              <td colspan="5" class="settings-empty">No external accounts connected.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp mailbox_address(mailbox),
    do: mailbox.local_part <> "@" <> mailbox.domain.normalized_domain

  defp mailbox_address(mailbox_id, mailboxes) do
    case Enum.find(mailboxes, &(&1.id == mailbox_id)) do
      nil -> "Unavailable"
      mailbox -> mailbox_address(mailbox)
    end
  end

  defp provider_name("gmail"), do: "Gmail"
  defp provider_name("microsoft"), do: "Microsoft 365"
  defp provider_name(provider), do: provider

  defp status_label(status), do: String.capitalize(status)

  defp format_datetime(nil), do: "Not yet"
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end

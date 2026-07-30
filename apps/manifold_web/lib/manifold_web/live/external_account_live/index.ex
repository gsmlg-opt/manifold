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
       configured_providers: Connectors.configured_providers(),
       add_account_step: :closed,
       selected_provider: nil,
       selected_mailbox_id: nil
     )}
  end

  @impl Phoenix.LiveView
  def handle_event("open-add-account", _params, socket) do
    {:noreply,
     assign(socket,
       add_account_step: :account_type,
       selected_provider: nil,
       selected_mailbox_id: nil
     )}
  end

  def handle_event("choose-account-type", %{"type" => "external"}, socket) do
    {:noreply, assign(socket, :add_account_step, :provider)}
  end

  def handle_event("choose-provider", %{"provider" => provider}, socket)
      when provider in ["gmail", "microsoft"] do
    if provider_configured?(socket.assigns.configured_providers, provider) do
      {:noreply,
       assign(socket,
         add_account_step: :mailbox,
         selected_provider: provider,
         selected_mailbox_id: nil
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select-add-account-mailbox", %{"mailbox_id" => mailbox_id}, socket) do
    selected_mailbox_id =
      if Enum.any?(socket.assigns.mailboxes, &(&1.id == mailbox_id)),
        do: mailbox_id,
        else: nil

    {:noreply, assign(socket, :selected_mailbox_id, selected_mailbox_id)}
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
        <div>
          <h1>External accounts</h1>
          <p class="settings-intro">
            Import mail from provider accounts into local Manifold mailboxes.
          </p>
        </div>
        <div class="settings-heading-actions">
          <button
            id="add-account-button"
            type="button"
            class="settings-action settings-action-primary"
            phx-click="open-add-account"
          >
            <.dm_mdi name="plus" /> Add account
          </button>
          <nav class="settings-nav" aria-label="Settings">
            <.link navigate={~p"/mailboxes"}>Mailboxes</.link>
            <.link navigate={~p"/domains"}>Domains</.link>
            <.link navigate={~p"/aliases"}>Aliases</.link>
          </nav>
        </div>
      </div>

      <section
        :if={@add_account_step != :closed}
        id="add-account-panel"
        class="add-account-panel"
        aria-labelledby="add-account-title"
      >
        <header class="add-account-panel-header">
          <div>
            <span class="add-account-step">{add_account_step_label(@add_account_step)}</span>
            <h2 id="add-account-title">Add an email account</h2>
          </div>
        </header>

        <div :if={@add_account_step == :account_type}>
          <h3>What kind of account are you adding?</h3>
          <button
            id="external-account-type"
            type="button"
            class="add-account-choice"
            phx-click="choose-account-type"
            phx-value-type="external"
          >
            <.dm_mdi name="cloud-outline" />
            <span>
              <strong>External account</strong>
              <small>Connect an existing provider-hosted mailbox.</small>
            </span>
          </button>
        </div>

        <div :if={@add_account_step == :provider}>
          <h3>Choose a provider</h3>
          <div class="add-account-choices">
            <button
              :for={provider <- ["gmail", "microsoft"]}
              id={"provider-#{provider}"}
              type="button"
              class="add-account-choice"
              disabled={!provider_configured?(@configured_providers, provider)}
              phx-click="choose-provider"
              phx-value-provider={provider}
            >
              <.dm_mdi name={provider_icon(provider)} />
              <span>
                <strong>{provider_name(provider)}</strong>
                <small :if={provider_configured?(@configured_providers, provider)}>
                  Import mail using read-only access.
                </small>
                <small :if={!provider_configured?(@configured_providers, provider)}>
                  Provider not configured
                </small>
              </span>
            </button>
          </div>
        </div>

        <div :if={@add_account_step == :mailbox}>
          <h3>Choose a local mailbox</h3>
          <p class="settings-secondary">
            Imported {provider_name(@selected_provider)} mail will be delivered here.
          </p>

          <form
            :if={@mailboxes != []}
            id="add-account-mailbox-form"
            phx-change="select-add-account-mailbox"
          >
            <label for="add-account-mailbox-id">Local mailbox</label>
            <select id="add-account-mailbox-id" name="mailbox_id">
              <option value="">Select a mailbox</option>
              <option
                :for={mailbox <- @mailboxes}
                value={mailbox.id}
                selected={mailbox.id == @selected_mailbox_id}
              >
                {mailbox_address(mailbox)}
              </option>
            </select>
          </form>

          <div :if={@mailboxes == []} id="add-account-no-mailboxes" class="settings-empty">
            <p>Create an active local mailbox before connecting an external account.</p>
            <.link id="manage-mailboxes-link" navigate={~p"/mailboxes"}>
              Manage mailboxes
            </.link>
          </div>

          <a
            :if={@selected_mailbox_id}
            id="continue-add-account"
            class="settings-action settings-action-primary"
            href={~p"/connectors/#{@selected_provider}/start?#{[mailbox_id: @selected_mailbox_id]}"}
          >
            Continue to {provider_name(@selected_provider)}
          </a>
        </div>
      </section>

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

  defp add_account_step_label(:account_type), do: "Step 1 of 3"
  defp add_account_step_label(:provider), do: "Step 2 of 3"
  defp add_account_step_label(:mailbox), do: "Step 3 of 3"

  defp provider_configured?(configured_providers, provider),
    do: provider in configured_providers

  defp provider_icon("gmail"), do: "gmail"
  defp provider_icon("microsoft"), do: "microsoft"

  defp status_label(status), do: String.capitalize(status)

  defp format_datetime(nil), do: "Not yet"
  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
end

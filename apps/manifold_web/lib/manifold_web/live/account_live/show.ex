defmodule ManifoldWeb.AccountLive.Show do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Core.Error

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    case Accounts.get_account(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Account not found.")
         |> push_navigate(to: ~p"/settings/accounts")}

      account ->
        {:ok,
         assign(socket,
           page_title: Accounts.account_address(account),
           account: account,
           address: Accounts.account_address(account),
           methods: Connectors.list_receive_methods_for_account(account.id),
           send_methods: Connectors.list_send_methods_for_account(account.id)
         )}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("enable", %{"id" => method_id}, socket) do
    case Connectors.enable_receive_method(method_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_methods()
         |> put_flash(:info, "Receive method enabled.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("sync", %{"id" => method_id}, socket) do
    case Connectors.enqueue_sync(method_id) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Synchronization queued.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Synchronization could not be queued.")}
    end
  end

  def handle_event("disconnect", %{"id" => method_id}, socket) do
    case Connectors.disconnect(method_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_methods()
         |> put_flash(:info, "Receive method disconnected.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not disconnect receive method.")}
    end
  end

  def handle_event("remove", %{"id" => method_id}, socket) do
    case Connectors.delete_receive_method(method_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_methods()
         |> put_flash(:info, "Receive method removed.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not remove receive method.")}
    end
  end

  def handle_event("enable-send", %{"id" => method_id}, socket) do
    case Connectors.enable_send_method(method_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_send_methods()
         |> put_flash(:info, "Send method enabled.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  def handle_event("disconnect-send", %{"id" => method_id}, socket) do
    case Connectors.disconnect_send_method(method_id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_send_methods()
         |> put_flash(:info, "Send method disconnected.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not disconnect send method.")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>{@account.name || @account.local_part}</h1>
          <p class="settings-intro">{@address}</p>
        </div>
        <div class="settings-heading-actions">
          <.link navigate={~p"/settings/accounts"} class="settings-action">Back</.link>
          <.link
            :if={gmail_reconnect?(@methods, @send_methods)}
            id="reconnect-gmail"
            href={
              ~p"/connectors/gmail/start?account_id=#{@account.id}&purpose=#{gmail_reconnect_purpose(@methods)}"
            }
            class="settings-action settings-action-primary"
          >
            Reconnect Gmail
          </.link>
          <.link
            :if={gmail_upgrade?(@methods, @send_methods)}
            id="upgrade-gmail-access"
            href={~p"/connectors/gmail/start?account_id=#{@account.id}&purpose=send"}
            class="settings-action settings-action-primary"
          >
            Upgrade Gmail access
          </.link>
          <.link
            id="add-receive-method"
            navigate={~p"/settings/accounts/#{@account.id}/receive_methods/new"}
            class="settings-action settings-action-primary"
          >
            <.dm_mdi name="plus" /> Add receive method
          </.link>
          <.link
            id="add-send-method"
            navigate={~p"/settings/accounts/#{@account.id}/send_methods/new"}
            class="settings-action settings-action-primary"
          >
            <.dm_mdi name="plus" /> Add send method
          </.link>
        </div>
      </div>

      <p :if={gmail_reconnect?(@methods, @send_methods)} class="settings-error">
        Reconnect the shared Gmail authorization; both receive and send are paused.
      </p>

      <h2>Receive methods</h2>
      <div class="table-scroll">
        <table id="receive-methods">
          <thead>
            <tr>
              <th>Kind</th>
              <th>Status</th>
              <th>Enabled</th>
              <th>Last synchronized</th>
              <th><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={method <- @methods} id={"receive-method-#{method.id}"}>
              <td data-label="Kind">
                <strong>{kind_label(method.kind)}</strong>
                <span class="settings-secondary">{method.email_address}</span>
              </td>
              <td data-label="Status">
                <span class={"policy-state state-#{method.status}"}>
                  {String.capitalize(method.status)}
                </span>
                <span :if={method.last_error} class="settings-error">{method.last_error}</span>
              </td>
              <td data-label="Enabled">{if method.enabled, do: "Yes", else: "No"}</td>
              <td data-label="Last synchronized">{format_datetime(method.last_synced_at)}</td>
              <td data-label="Actions">
                <div class="account-actions">
                  <.link
                    navigate={~p"/settings/accounts/#{method.id}/activity"}
                    class="settings-icon-button"
                    title="Activity"
                  >
                    <.dm_mdi name="history" />
                  </.link>
                  <button
                    :if={!method.enabled and method.status not in ["disconnected", "not_implemented"]}
                    type="button"
                    class="settings-icon-button"
                    phx-click="enable"
                    phx-value-id={method.id}
                    title="Enable"
                  >
                    <.dm_mdi name="check" />
                  </button>
                  <button
                    type="button"
                    class="settings-icon-button"
                    phx-click="sync"
                    phx-value-id={method.id}
                    disabled={!method.enabled or !method.sync_enabled}
                    title="Synchronize"
                  >
                    <.dm_mdi name="sync" />
                  </button>
                  <button
                    type="button"
                    class="settings-icon-button settings-icon-button-danger"
                    phx-click="disconnect"
                    phx-value-id={method.id}
                    disabled={method.status == "disconnected"}
                    data-confirm="Disconnect this receive method?"
                    title="Disconnect"
                  >
                    <.dm_mdi name="link-off" />
                  </button>
                  <button
                    type="button"
                    class="settings-icon-button settings-icon-button-danger"
                    phx-click="remove"
                    phx-value-id={method.id}
                    data-confirm="Remove this receive method permanently?"
                    title="Remove"
                  >
                    <.dm_mdi name="delete-outline" />
                  </button>
                </div>
              </td>
            </tr>
            <tr :if={@methods == []}>
              <td colspan="5" class="settings-empty">No receive methods configured.</td>
            </tr>
          </tbody>
        </table>
      </div>

      <h2>Send methods</h2>
      <div class="table-scroll">
        <table id="send-methods">
          <thead>
            <tr>
              <th>Kind</th>
              <th>Status</th>
              <th>Enabled</th>
              <th>Last verified</th>
              <th><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={method <- @send_methods} id={"send-method-#{method.id}"}>
              <td data-label="Kind">
                <strong>{send_kind_label(method.kind)}</strong>
                <span class="settings-secondary">{method.email_address}</span>
              </td>
              <td data-label="Status">
                <span class={"policy-state state-#{method.status}"}>
                  {String.capitalize(method.status)}
                </span>
                <span :if={method.last_error} class="settings-error">{method.last_error}</span>
              </td>
              <td data-label="Enabled">{if method.enabled, do: "Yes", else: "No"}</td>
              <td data-label="Last verified">{format_datetime(method.last_verified_at)}</td>
              <td data-label="Actions">
                <div class="account-actions">
                  <button
                    :if={!method.enabled and method.status != "disconnected"}
                    type="button"
                    class="settings-icon-button"
                    phx-click="enable-send"
                    phx-value-id={method.id}
                    title="Enable"
                  >
                    <.dm_mdi name="check" />
                  </button>
                  <button
                    type="button"
                    class="settings-icon-button settings-icon-button-danger"
                    phx-click="disconnect-send"
                    phx-value-id={method.id}
                    disabled={method.status == "disconnected"}
                    data-confirm="Disconnect this send method?"
                    title="Disconnect"
                  >
                    <.dm_mdi name="link-off" />
                  </button>
                </div>
              </td>
            </tr>
            <tr :if={@send_methods == []}>
              <td colspan="5" class="settings-empty">No send methods configured.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp refresh_methods(socket) do
    assign(
      socket,
      :methods,
      Connectors.list_receive_methods_for_account(socket.assigns.account.id)
    )
  end

  defp refresh_send_methods(socket) do
    assign(
      socket,
      :send_methods,
      Connectors.list_send_methods_for_account(socket.assigns.account.id)
    )
  end

  defp kind_label("gmail"), do: "Gmail"
  defp kind_label("microsoft"), do: "Microsoft Graph"
  defp kind_label("imap"), do: "IMAP"
  defp kind_label("pop3"), do: "POP3"
  defp kind_label("eas"), do: "EAS"
  defp kind_label("ews"), do: "EWS"
  defp kind_label(kind), do: kind

  defp send_kind_label("smtp"), do: "SMTP"
  defp send_kind_label("gmail"), do: "Gmail"
  defp send_kind_label(kind), do: kind

  defp gmail_upgrade?(methods, send_methods) do
    Enum.any?(methods, &(&1.kind == "gmail" and &1.status != "disconnected")) and
      not Enum.any?(send_methods, &(&1.kind == "gmail" and &1.status != "disconnected")) and
      not gmail_reconnect?(methods, send_methods)
  end

  defp gmail_reconnect?(methods, send_methods) do
    Enum.any?(
      methods ++ send_methods,
      &(&1.kind == "gmail" and &1.status == "reconnect_required")
    )
  end

  defp gmail_reconnect_purpose(methods) do
    if Enum.any?(methods, &(&1.kind == "gmail")), do: "receive", else: "send"
  end

  defp format_datetime(nil), do: "Not yet"
  defp format_datetime(datetime), do: ManifoldWeb.Formatting.datetime_utc(datetime)

  defp format_error(%Error{message: message}), do: message
  defp format_error(%ProviderError{message: message}), do: message
  defp format_error(%Ecto.Changeset{}), do: "Invalid settings."
  defp format_error(_), do: "Something went wrong."
end

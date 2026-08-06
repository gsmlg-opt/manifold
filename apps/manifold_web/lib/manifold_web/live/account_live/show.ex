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
           configured_providers: Connectors.configured_providers(),
           add_step: :closed,
           selected_kind: nil,
           imap_form: empty_imap_form(account),
           imap_error: nil,
           imap_saving: false
         )}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("open-add-method", _params, socket) do
    {:noreply, assign(socket, add_step: :choose_kind, selected_kind: nil, imap_error: nil)}
  end

  def handle_event("close-add-method", _params, socket) do
    {:noreply,
     assign(socket,
       add_step: :closed,
       selected_kind: nil,
       imap_form: empty_imap_form(socket.assigns.account),
       imap_error: nil
     )}
  end

  def handle_event("choose-kind", %{"kind" => kind}, socket)
      when kind in ["gmail", "microsoft", "imap", "pop3", "eas", "ews"] do
    cond do
      kind in ["gmail", "microsoft"] ->
        if kind in socket.assigns.configured_providers do
          {:noreply, assign(socket, add_step: :oauth_confirm, selected_kind: kind)}
        else
          {:noreply, put_flash(socket, :error, "#{kind_label(kind)} is not configured.")}
        end

      kind == "imap" ->
        {:noreply,
         assign(socket,
           add_step: :imap_form,
           selected_kind: kind,
           imap_form: empty_imap_form(socket.assigns.account),
           imap_error: nil
         )}

      true ->
        case Connectors.create_placeholder_receive_method(socket.assigns.account.id, kind) do
          {:ok, _method} ->
            {:noreply,
             socket
             |> refresh_methods()
             |> assign(add_step: :closed)
             |> put_flash(:info, "#{kind_label(kind)} placeholder added (not implemented yet).")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not add #{kind_label(kind)}.")}
        end
    end
  end

  def handle_event("validate-imap", %{"imap" => params}, socket) do
    {:noreply, assign(socket, imap_form: to_form(params, as: :imap), imap_error: nil)}
  end

  def handle_event("save-imap", %{"imap" => params}, %{assigns: %{imap_saving: false}} = socket) do
    socket = assign(socket, imap_saving: true, imap_form: to_form(params, as: :imap))

    attrs =
      params
      |> Map.put("account_id", socket.assigns.account.id)
      |> Map.put_new("email_address", socket.assigns.address)

    case Connectors.create_imap_account(attrs) do
      {:ok, _method} ->
        {:noreply,
         socket
         |> refresh_methods()
         |> assign(
           add_step: :closed,
           imap_saving: false,
           imap_form: empty_imap_form(socket.assigns.account),
           imap_error: nil
         )
         |> put_flash(:info, "IMAP receive method added and enabled.")}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           imap_saving: false,
           imap_error: format_error(reason)
         )}
    end
  end

  def handle_event("save-imap", _params, socket), do: {:noreply, socket}

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
          <button
            id="add-receive-method"
            type="button"
            class="settings-action settings-action-primary"
            phx-click="open-add-method"
          >
            <.dm_mdi name="plus" /> Add receive method
          </button>
        </div>
      </div>

      <div :if={@add_step != :closed} class="settings-panel" id="add-receive-method-panel">
        <div :if={@add_step == :choose_kind}>
          <h2>Choose receive method</h2>
          <div class="settings-choice-grid">
            <button
              :for={kind <- ~w(gmail microsoft imap pop3 eas ews)}
              type="button"
              class="settings-action"
              phx-click="choose-kind"
              phx-value-kind={kind}
              disabled={kind in ~w(gmail microsoft) and kind not in @configured_providers}
            >
              {kind_label(kind)}
              <span :if={kind in ~w(pop3 eas ews)} class="settings-secondary">(placeholder)</span>
            </button>
          </div>
          <button type="button" class="settings-action" phx-click="close-add-method">Cancel</button>
        </div>

        <div :if={@add_step == :oauth_confirm}>
          <h2>Connect {kind_label(@selected_kind)}</h2>
          <p>Authorize {kind_label(@selected_kind)} to import mail into this account.</p>
          <.link
            href={~p"/connectors/#{@selected_kind}/start?account_id=#{@account.id}"}
            class="settings-action settings-action-primary"
          >
            Continue with {kind_label(@selected_kind)}
          </.link>
          <button type="button" class="settings-action" phx-click="close-add-method">Cancel</button>
        </div>

        <div :if={@add_step == :imap_form}>
          <h2>IMAP settings</h2>
          <p :if={@imap_error} class="settings-error">{@imap_error}</p>
          <.form
            for={@imap_form}
            id="imap-form"
            phx-change="validate-imap"
            phx-submit="save-imap"
          >
            <label>
              Email
              <input
                type="email"
                name={@imap_form[:email_address].name}
                value={@imap_form[:email_address].value}
                required
              />
            </label>
            <label>
              Host
              <input type="text" name={@imap_form[:host].name} value={@imap_form[:host].value} required />
            </label>
            <label>
              Port
              <input type="number" name={@imap_form[:port].name} value={@imap_form[:port].value} required />
            </label>
            <label>
              TLS mode
              <select name={@imap_form[:tls_mode].name}>
                <option value="ssl" selected={@imap_form[:tls_mode].value == "ssl"}>SSL</option>
                <option value="starttls" selected={@imap_form[:tls_mode].value == "starttls"}>
                  STARTTLS
                </option>
              </select>
            </label>
            <label>
              Username
              <input
                type="text"
                name={@imap_form[:username].name}
                value={@imap_form[:username].value}
                required
              />
            </label>
            <label>
              Password
              <input
                type="password"
                name={@imap_form[:password].name}
                value={@imap_form[:password].value}
                required
              />
            </label>
            <button
              type="submit"
              class="settings-action settings-action-primary"
              disabled={@imap_saving}
            >
              {if @imap_saving, do: "Saving…", else: "Save IMAP"}
            </button>
            <button type="button" class="settings-action" phx-click="close-add-method">Cancel</button>
          </.form>
        </div>
      </div>

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
                </div>
              </td>
            </tr>
            <tr :if={@methods == []}>
              <td colspan="5" class="settings-empty">No receive methods configured.</td>
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

  defp empty_imap_form(account) do
    address = Accounts.account_address(account)

    to_form(
      %{
        "email_address" => address,
        "host" => "",
        "port" => "993",
        "tls_mode" => "ssl",
        "username" => address,
        "password" => ""
      },
      as: :imap
    )
  end

  defp kind_label("gmail"), do: "Gmail"
  defp kind_label("microsoft"), do: "Microsoft Graph"
  defp kind_label("imap"), do: "IMAP"
  defp kind_label("pop3"), do: "POP3"
  defp kind_label("eas"), do: "EAS"
  defp kind_label("ews"), do: "EWS"
  defp kind_label(kind), do: kind

  defp format_datetime(nil), do: "Not yet"
  defp format_datetime(datetime), do: ManifoldWeb.Formatting.datetime_utc(datetime)

  defp format_error(%Error{message: message}), do: message
  defp format_error(%ProviderError{message: message}), do: message
  defp format_error(%Ecto.Changeset{}), do: "Invalid settings."
  defp format_error(_), do: "Something went wrong."
end

defmodule ManifoldWeb.AccountLive.ICloudComponent do
  use Phoenix.LiveComponent
  use ManifoldWeb, :html

  alias Manifold.Connectors.ICloud
  alias ManifoldWeb.Formatting

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns) |> reload()

    socket =
      if Map.has_key?(socket.assigns, :form),
        do: socket,
        else: socket |> assign(error: nil, disconnecting: false) |> reset_form()

    {:ok, socket}
  end

  @impl true
  def handle_event("save", %{"icloud" => params}, socket) do
    result =
      if socket.assigns.connection,
        do: ICloud.update_connection(socket.assigns.connection.id, params),
        else: ICloud.connect(Map.put(params, "account_id", socket.assigns.account.id))

    safe =
      Map.take(
        params,
        ~w(apple_id contacts_enabled calendars_enabled default_contacts_collection_id)
      )
      |> Map.put("app_password", "")

    socket =
      socket
      |> assign(:form, to_form(safe, as: :icloud))
      |> push_event("clear-icloud-password", %{})

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> reload()
         |> reset_form()
         |> assign(:error, nil)
         |> notify_flash(:info, "iCloud settings saved. Eligible synchronization queued.")}

      _ ->
        {:noreply,
         assign(
           socket,
           :error,
           "Unable to save iCloud settings. Check credentials, service selections and the writable address book."
         )}
    end
  end

  def handle_event("sync", _params, socket),
    do:
      {:noreply,
       outcome(socket, ICloud.sync_now(socket.assigns.connection.id), "Synchronization queued.")}

  def handle_event("toggle", _params, socket),
    do:
      {:noreply,
       outcome(
         socket,
         ICloud.set_enabled(socket.assigns.connection.id, !socket.assigns.connection.enabled),
         "iCloud connection updated."
       )}

  def handle_event("open-disconnect", _params, socket),
    do: {:noreply, assign(socket, :disconnecting, true)}

  def handle_event("cancel-disconnect", _params, socket),
    do: {:noreply, assign(socket, :disconnecting, false)}

  def handle_event("disconnect", _params, socket) do
    socket =
      outcome(
        socket,
        ICloud.disconnect(socket.assigns.connection.id),
        "iCloud disconnected. Local contacts and events retained."
      )

    {:noreply, socket |> assign(:disconnecting, false) |> reset_form()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-6 space-y-4 mt-6"
    >
      <h2>iCloud Contacts and Calendar</h2>
      <p>
        Configure iCloud for this Account. Contact and event saves commit locally before asynchronous synchronization.
      </p>
      <p :if={!@account.active} class="text-on-surface-variant">
        This Account is disabled. Local saves remain available and synchronization is paused.
      </p>
      <p>Use an app-specific password with Apple two-factor authentication enabled.</p>
      <p>
        <a
          href="https://account.apple.com/"
          target="_blank"
          rel="noopener noreferrer"
          class="text-primary"
        >Generate an app-specific password</a>
        ·
        <a
          href="https://support.apple.com/en-us/121539"
          target="_blank"
          rel="noopener noreferrer"
          class="text-primary"
        >Apple's instructions</a>
      </p>
      <.form for={@form} id="icloud-form" phx-submit="save" phx-target={@myself} class="space-y-4">
        <.dm_input
          field={@form[:apple_id]}
          label="Apple Account (email or phone)"
          autocomplete="username"
          readonly={not is_nil(@connection)}
          required
        />
        <.dm_input
          field={@form[:app_password]}
          label="App-specific password"
          type="password"
          autocomplete="new-password"
          required={is_nil(@connection)}
          helper={if @connection, do: "Leave blank to keep the saved password.", else: nil}
        />
        <.dm_input field={@form[:contacts_enabled]} label="Sync contacts" type="checkbox" />
        <.dm_input field={@form[:calendars_enabled]} label="Sync calendars" type="checkbox" />
        <.dm_select
          :if={@connection}
          field={@form[:default_contacts_collection_id]}
          label="Default iCloud address book"
          options={[
            {"", "Choose a writable address book"}
            | Enum.map(@address_books, &{&1.id, &1.name || &1.href})
          ]}
        />
        <p :if={@connection && @address_books == []} class="text-on-surface-variant">
          Writable address books appear after discovery. Contacts wait locally until a destination is selected.
        </p>
        <p :if={@error} id="icloud-form-error" role="alert" class="settings-error">{@error}</p>
        <.dm_btn id="save-icloud" variant="primary" type="submit">
          {if @connection, do: "Save iCloud settings", else: "Connect iCloud"}
        </.dm_btn>
      </.form>
      <article :if={@connection} id={"icloud-#{@connection.id}"} class="space-y-4">
        <p>{if @connection.enabled, do: "Enabled", else: "Disabled — local records retained"}</p>
        <dl aria-live="polite" class="space-y-4">
          <div>
            <dt>Contacts</dt><dd>
              {service_status(@connection.contacts_enabled, @connection.contacts_status)}
            </dd><dd>Last successful sync: {sync_time(@connection.contacts_synced_at)}</dd><dd
              :if={@connection.contacts_error}
              class="settings-error"
            >
              {@connection.contacts_error}
            </dd>
          </div>
          <div>
            <dt>Calendar</dt><dd>
              {service_status(@connection.calendars_enabled, @connection.calendars_status)}
            </dd><dd>Last successful sync: {sync_time(@connection.calendars_synced_at)}</dd><dd
              :if={@connection.calendars_error}
              class="settings-error"
            >
              {@connection.calendars_error}
            </dd>
          </div>
        </dl>
        <div class="flex flex-wrap gap-4">
          <.dm_btn
            id={"sync-icloud-#{@connection.id}"}
            variant="outline"
            phx-click="sync"
            phx-target={@myself}
            disabled={!@connection.enabled || !@account.active}
          >
            Sync now
          </.dm_btn>
          <.dm_btn
            id={"toggle-icloud-#{@connection.id}"}
            variant="ghost"
            phx-click="toggle"
            phx-target={@myself}
          >
            {if @connection.enabled, do: "Disable", else: "Enable"}
          </.dm_btn>
          <.dm_btn
            id={"disconnect-icloud-#{@connection.id}"}
            variant="error"
            phx-click="open-disconnect"
            phx-target={@myself}
          >
            Disconnect
          </.dm_btn>
          <.dm_btn navigate={~p"/calendars"} variant="outline">Manage local calendars</.dm_btn>
        </div>
      </article>
      <.focus_wrap
        :if={@disconnecting}
        id="icloud-disconnect-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="icloud-disconnect-title"
        class="bg-surface-container-highest text-on-surface border border-outline p-6 rounded-lg"
        phx-window-keydown="cancel-disconnect"
        phx-key="Escape"
        phx-target={@myself}
        phx-mounted={JS.focus(to: "#cancel-icloud-disconnect")}
        phx-remove={JS.pop_focus()}
      >
        <h2 id="icloud-disconnect-title">Disconnect iCloud?</h2>
        <p>
          This removes the saved credential and cloud target. Local contacts, calendars and event drafts are retained. Your iCloud data is unchanged.
        </p>
        <div class="flex gap-4 mt-4">
          <.dm_btn
            id="cancel-icloud-disconnect"
            variant="ghost"
            phx-click="cancel-disconnect"
            phx-target={@myself}
          >
            Cancel
          </.dm_btn><.dm_btn
            id="confirm-icloud-disconnect"
            variant="error"
            phx-click="disconnect"
            phx-target={@myself}
          >
            Disconnect and retain local data
          </.dm_btn>
        </div>
      </.focus_wrap>
    </section>
    """
  end

  defp reload(socket) do
    connection = ICloud.for_account(socket.assigns.account.id)
    books = if connection, do: ICloud.collections(connection.id, "contacts"), else: []

    books =
      Enum.filter(books, &(&1.can_create == true or (is_nil(&1.can_create) and &1.writable)))

    assign(socket, connection: connection, address_books: books)
  end

  defp reset_form(socket) do
    values =
      if socket.assigns.connection,
        do:
          Map.take(socket.assigns.connection, [
            :apple_id,
            :contacts_enabled,
            :calendars_enabled,
            :default_contacts_collection_id
          ]),
        else: %{
          apple_id: "",
          contacts_enabled: true,
          calendars_enabled: true,
          default_contacts_collection_id: ""
        }

    values =
      values
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("app_password", "")

    assign(socket, :form, to_form(values, as: :icloud))
  end

  defp outcome(socket, {:ok, _}, message),
    do: socket |> reload() |> reset_form() |> notify_flash(:info, message)

  defp outcome(socket, {:error, _}, _message),
    do: socket |> reload() |> notify_flash(:error, "Unable to update this iCloud connection.")

  defp notify_flash(socket, kind, message) do
    send(self(), {:icloud_flash, kind, message})
    socket
  end

  defp service_status(false, _), do: "Paused"
  defp service_status(true, status), do: status |> String.replace("_", " ") |> String.capitalize()
  defp sync_time(nil), do: "Never"
  defp sync_time(datetime), do: Formatting.datetime_utc(datetime)
end

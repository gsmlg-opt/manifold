defmodule ManifoldWeb.SettingsLive.ICloud do
  use ManifoldWeb, :live_view

  alias Manifold.Connectors.ICloud
  alias ManifoldWeb.Formatting

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh_connections, 5_000)

    {:ok,
     socket
     |> assign(page_title: "iCloud", editing_id: nil, disconnect_id: nil, error: nil)
     |> reset_form()
     |> reload_connections()}
  end

  @impl true
  def handle_event("connect", %{"icloud" => params}, socket) do
    result =
      if socket.assigns.editing_id,
        do: ICloud.update_connection(socket.assigns.editing_id, params),
        else: ICloud.connect(params)

    socket =
      assign(
        socket,
        :form,
        to_form(
          Map.take(params, ~w(apple_id contacts_enabled calendars_enabled))
          |> Map.put("app_password", ""),
          as: :icloud
        )
      )

    socket = push_event(socket, "clear-icloud-password", %{})

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(editing_id: nil, error: nil)
         |> reset_form()
         |> reload_connections()
         |> put_flash(:info, "iCloud settings saved. Synchronization queued.")}

      {:error, _} ->
        {:noreply,
         assign(
           socket,
           :error,
           "Unable to save iCloud settings. Check the Apple Account and app-specific password, then try again."
         )}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    case Enum.find(ICloud.list_connections(), &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Connection not found.")}

      connection ->
        values =
          Map.take(connection, [:apple_id, :contacts_enabled, :calendars_enabled])
          |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
          |> Map.put("app_password", "")

        {:noreply, assign(socket, editing_id: id, form: to_form(values, as: :icloud), error: nil)}
    end
  end

  def handle_event("cancel-edit", _params, socket),
    do: {:noreply, socket |> assign(editing_id: nil, error: nil) |> reset_form()}

  def handle_event("toggle-enabled", %{"id" => id}, socket) do
    case Enum.find(ICloud.list_connections(), &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Connection not found.")}

      connection ->
        {:noreply,
         outcome(socket, ICloud.set_enabled(id, !connection.enabled), "Connection updated.")}
    end
  end

  def handle_event("sync", %{"id" => id}, socket),
    do: {:noreply, outcome(socket, ICloud.sync_now(id), "Synchronization queued.")}

  def handle_event("open-disconnect", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :disconnect_id, id)}

  def handle_event("cancel-disconnect", _params, socket),
    do: {:noreply, assign(socket, :disconnect_id, nil)}

  def handle_event("disconnect", _params, socket) do
    socket =
      outcome(
        socket,
        ICloud.disconnect(socket.assigns.disconnect_id),
        "iCloud disconnected. Local contacts retained."
      )

    {:noreply, socket |> assign(disconnect_id: nil, editing_id: nil) |> reset_form()}
  end

  @impl true
  def handle_info(:refresh_connections, socket) do
    Process.send_after(self(), :refresh_connections, 5_000)
    {:noreply, reload_connections(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="icloud-settings" class="space-y-6">
      <div class="settings-heading">
        <div>
          <h1>iCloud</h1><p class="settings-intro">
            Automatically read contacts and calendars every five minutes.
          </p>
        </div>
      </div>
      <div class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-4 space-y-4">
        <h2>{if @editing_id, do: "Update connection", else: "Connect Apple Account"}</h2>
        <p>
          Use an app-specific password, not your primary Apple Account password. Two-factor authentication must be enabled.
        </p>
        <p>
          <a
            href="https://account.apple.com/"
            target="_blank"
            rel="noopener noreferrer"
            class="text-primary"
          >Generate an app-specific password</a>
          under Sign-In and Security.
          <a
            href="https://support.apple.com/en-us/121539"
            target="_blank"
            rel="noopener noreferrer"
            class="text-primary"
          >Apple's instructions</a>
          explain generation and revocation.
        </p>
        <p>
          Synchronization is read-only. Changes to iCloud contacts and calendars appear here; local contacts stay local.
        </p>
        <.form for={@form} id="icloud-form" phx-submit="connect" class="space-y-4">
          <.dm_input
            field={@form[:apple_id]}
            label="Apple Account (email or phone)"
            type="text"
            autocomplete="username"
            required
            readonly={not is_nil(@editing_id)}
          />
          <.dm_input
            field={@form[:app_password]}
            label="App-specific password"
            type="password"
            autocomplete="new-password"
            required={is_nil(@editing_id)}
            helper={if @editing_id, do: "Leave blank to keep the saved password.", else: nil}
          />
          <.dm_input field={@form[:contacts_enabled]} label="Sync contacts" type="checkbox" />
          <.dm_input field={@form[:calendars_enabled]} label="Sync calendars" type="checkbox" />
          <p :if={@error} id="icloud-form-error" role="alert" class="settings-error">{@error}</p>
          <div class="flex gap-4">
            <.dm_btn id="save-icloud" type="submit" variant="primary">
              {if @editing_id, do: "Save connection", else: "Connect iCloud"}
            </.dm_btn>
            <.dm_btn
              :if={@editing_id}
              id="cancel-icloud-edit"
              type="button"
              variant="ghost"
              phx-click="cancel-edit"
            >
              Cancel
            </.dm_btn>
          </div>
        </.form>
      </div>
      <p :if={@connections == []} id="icloud-empty">No iCloud connections yet.</p>
      <article
        :for={connection <- @connections}
        id={"icloud-#{connection.id}"}
        class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-4 space-y-4"
      >
        <h2>{connection.apple_id}</h2><p>
          {if connection.enabled, do: "Enabled", else: "Disabled — imported records retained"}
        </p>
        <dl class="space-y-4" aria-live="polite">
          <div>
            <dt>Contacts</dt><dd>
              {service_status(connection.contacts_enabled, connection.contacts_status)}
            </dd><dd>Last successful sync: {sync_time(connection.contacts_synced_at)}</dd><dd
              :if={connection.contacts_error}
              class="settings-error"
            >
              {connection.contacts_error}
            </dd>
          </div>
          <div>
            <dt>Calendars</dt><dd>
              {service_status(connection.calendars_enabled, connection.calendars_status)}
            </dd><dd>Last successful sync: {sync_time(connection.calendars_synced_at)}</dd><dd
              :if={connection.calendars_error}
              class="settings-error"
            >
              {connection.calendars_error}
            </dd>
          </div>
        </dl>
        <div class="flex flex-wrap gap-4">
          <.dm_btn
            id={"sync-icloud-#{connection.id}"}
            type="button"
            variant="outline"
            phx-click="sync"
            phx-value-id={connection.id}
            disabled={!connection.enabled}
          >
            Sync now
          </.dm_btn>
          <.dm_btn
            id={"edit-icloud-#{connection.id}"}
            type="button"
            variant="outline"
            phx-click="edit"
            phx-value-id={connection.id}
          >
            Update credentials / services
          </.dm_btn>
          <.dm_btn
            id={"toggle-icloud-#{connection.id}"}
            type="button"
            variant="ghost"
            phx-click="toggle-enabled"
            phx-value-id={connection.id}
          >
            {if connection.enabled, do: "Disable", else: "Enable"}
          </.dm_btn>
          <.dm_btn
            id={"disconnect-icloud-#{connection.id}"}
            type="button"
            variant="error"
            phx-click="open-disconnect"
            phx-value-id={connection.id}
          >
            Disconnect
          </.dm_btn>
        </div>
      </article>
      <.focus_wrap
        :if={@disconnect_id}
        id="icloud-disconnect-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="icloud-disconnect-title"
        class="bg-surface-container-highest text-on-surface border border-outline p-6 rounded-lg"
        phx-window-keydown="cancel-disconnect"
        phx-key="Escape"
        phx-mounted={JS.focus(to: "#cancel-icloud-disconnect")}
        phx-remove={JS.pop_focus()}
      >
        <h2 id="icloud-disconnect-title">Disconnect iCloud?</h2>
        <p>
          This removes the saved password and this connection's imported contacts and calendar records. Local contacts remain. Your iCloud data is unchanged.
        </p>
        <div class="flex gap-4 mt-4">
          <.dm_btn
            id="cancel-icloud-disconnect"
            type="button"
            variant="ghost"
            phx-click="cancel-disconnect"
          >
            Cancel
          </.dm_btn>
          <.dm_btn id="confirm-icloud-disconnect" type="button" variant="error" phx-click="disconnect">
            Disconnect and remove imports
          </.dm_btn>
        </div>
      </.focus_wrap>
    </section>
    """
  end

  defp reload_connections(socket), do: assign(socket, :connections, ICloud.list_connections())

  defp reset_form(socket),
    do:
      assign(
        socket,
        :form,
        to_form(
          %{
            "apple_id" => "",
            "app_password" => "",
            "contacts_enabled" => true,
            "calendars_enabled" => true
          },
          as: :icloud
        )
      )

  defp outcome(socket, {:ok, _}, message),
    do: socket |> reload_connections() |> put_flash(:info, message)

  defp outcome(socket, {:error, _}, _message),
    do: socket |> reload_connections() |> put_flash(:error, "Unable to update this connection.")

  defp service_status(false, _status), do: "Not selected"

  defp service_status(true, status),
    do: (status || "pending") |> String.replace("_", " ") |> String.capitalize()

  defp sync_time(nil), do: "Never"
  defp sync_time(datetime), do: Formatting.datetime_utc(datetime)
end

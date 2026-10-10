defmodule ManifoldWeb.CalendarLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.{Accounts, Calendars}
  alias Manifold.Connectors.ICloud
  alias Manifold.Connectors.ICloud.Outbound
  alias Manifold.Data.Schema.{Calendar, CalendarEvent}

  @calendar_fields ~w(name account_id collection_id sync_to_icloud merge_destination)
  @event_fields ~w(summary description location starts_at ends_at timezone all_day)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Calendars",
       offset: 0,
       calendars: [],
       calendar: nil,
       events: [],
       event: nil,
       accounts: Accounts.list_accounts(),
       calendar_form: nil,
       event_form: nil,
       destinations: [],
       error: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    calendars = Calendars.list_calendars()

    calendar =
      if params["calendar_id"],
        do: Enum.find(calendars, &(&1.id == params["calendar_id"])),
        else: List.first(calendars)

    event =
      if params["id"], do: Calendars.get_event(params["id"], include_deleted_conflicts: true)

    event = if event && calendar && event.calendar_id == calendar.id, do: event

    offset =
      if socket.assigns.calendar && calendar && socket.assigns.calendar.id == calendar.id,
        do: socket.assigns.offset,
        else: 0

    socket =
      assign(socket,
        calendars: calendars,
        calendar: calendar,
        event: event,
        offset: offset,
        events:
          if(calendar,
            do:
              Calendars.list_events(calendar.id,
                limit: 50,
                offset: offset,
                include_deleted_conflicts: true
              ),
            else: []
          ),
        calendar_form: nil,
        event_form: nil,
        error: nil
      )

    cond do
      (params["calendar_id"] && is_nil(calendar)) || (params["id"] && is_nil(event)) ->
        {:noreply,
         socket
         |> put_flash(:error, "Calendar or event not found.")
         |> push_patch(to: ~p"/calendars")}

      socket.assigns.live_action == :new_calendar ->
        {:noreply, calendar_form(socket, %Calendar{})}

      socket.assigns.live_action == :edit_calendar ->
        {:noreply, calendar_form(socket, calendar)}

      socket.assigns.live_action == :new_event ->
        {:noreply, event_form(socket, %CalendarEvent{})}

      socket.assigns.live_action == :edit_event && editable?(calendar, :update) ->
        {:noreply, event_form(socket, event)}

      socket.assigns.live_action == :edit_event ->
        {:noreply,
         socket
         |> put_flash(:error, "This iCloud source is read-only. Make a local copy to edit it.")
         |> push_patch(to: ~p"/calendars/#{calendar.id}/events/#{event.id}")}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("page", %{"direction" => direction}, socket)
      when direction in ["previous", "next"] do
    offset = max(0, socket.assigns.offset + if(direction == "next", do: 50, else: -50))

    {:noreply,
     assign(socket,
       offset: offset,
       events:
         Calendars.list_events(socket.assigns.calendar.id,
           limit: 50,
           offset: offset,
           include_deleted_conflicts: true
         )
     )}
  end

  def handle_event("validate-calendar", %{"calendar" => params}, socket) do
    params = Map.take(params, @calendar_fields)
    previous = socket.assigns.calendar_form.params

    params =
      if params["account_id"] != previous["account_id"] or
           params["collection_id"] != previous["collection_id"],
         do: Map.put(params, "merge_destination", false),
         else: params

    {:noreply,
     assign(socket,
       calendar_form: to_form(params, as: :calendar),
       destinations: destinations(params["account_id"]),
       error: nil
     )}
  end

  def handle_event("save-calendar", %{"calendar" => params}, socket) do
    attrs = Map.take(params, @calendar_fields)

    socket =
      assign(socket,
        calendar_form: to_form(attrs, as: :calendar),
        destinations: destinations(attrs["account_id"])
      )

    result =
      if socket.assigns.live_action == :edit_calendar,
        do: Calendars.update_calendar(socket.assigns.calendar.id, attrs),
        else: Calendars.create_calendar(attrs)

    case result do
      {:ok, calendar} ->
        {:noreply,
         socket
         |> put_flash(:info, "Calendar saved locally.")
         |> push_patch(to: ~p"/calendars/#{calendar.id}")}

      {:error, :local_copy_required} ->
        {:noreply,
         assign(
           socket,
           :error,
           "This calendar has remote bindings. Create a local calendar to use a different destination."
         )}

      {:error, :merge_required} ->
        {:noreply,
         assign(
           socket,
           :error,
           "This destination already has a local calendar. Confirm the merge to retain its events in this calendar."
         )}

      _ ->
        {:noreply,
         assign(socket,
           calendar_form: to_form(attrs, as: :calendar),
           error: "Unable to save calendar. Check its name, Account and destination."
         )}
    end
  end

  def handle_event("delete-calendar", _params, socket) do
    case socket.assigns.calendar && Calendars.delete_calendar(socket.assigns.calendar.id) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Local calendar deleted.") |> push_patch(to: ~p"/calendars")}

      {:error, :not_empty} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Delete this calendar's event records first. Its iCloud calendar will be retained."
         )}

      {:error, :sync_pending} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Pending synchronization and conflicts must finish before deleting this local calendar. Its iCloud calendar will be retained."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Unable to delete this calendar.")}
    end
  end

  def handle_event("save-event", %{"event" => params}, socket) do
    attrs =
      params
      |> Map.take(@event_fields)
      |> Map.put("calendar_id", socket.assigns.calendar.id)
      |> normalize_event()

    result =
      if socket.assigns.live_action == :edit_event,
        do: Calendars.update_event(socket.assigns.event.id, attrs),
        else: Calendars.create_event(attrs)

    case result do
      {:ok, event} ->
        {:noreply,
         socket
         |> put_flash(:info, "Event saved locally. Eligible changes synchronize asynchronously.")
         |> push_patch(to: ~p"/calendars/#{socket.assigns.calendar.id}/events/#{event.id}")}

      _ ->
        {:noreply,
         assign(socket,
           event_form: to_form(Map.take(params, @event_fields), as: :event),
           error: "Unable to save event. Check its dates and source permissions."
         )}
    end
  end

  def handle_event("validate-event", %{"event" => params}, socket),
    do:
      {:noreply,
       assign(socket,
         event_form: to_form(Map.take(params, @event_fields), as: :event),
         error: nil
       )}

  def handle_event("delete-event", %{"scope" => scope}, socket)
      when scope in ["component", "series"] do
    case socket.assigns.event &&
           Calendars.delete_event(socket.assigns.event.id, whole_series: scope == "series") do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Event deletion saved locally.")
         |> push_patch(to: ~p"/calendars/#{socket.assigns.calendar.id}")}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Unable to delete this event. Check source permissions.")}
    end
  end

  def handle_event("copy-event", %{"copy" => params}, socket) do
    case socket.assigns.event &&
           Calendars.copy_event(socket.assigns.event.id, Map.take(params, ["calendar_id"])) do
      {:ok, event} ->
        {:noreply,
         socket
         |> put_flash(:info, "Event copy saved locally.")
         |> push_patch(to: ~p"/calendars/#{event.calendar_id}/events/#{event.id}")}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Unable to copy this event. Choose a writable local calendar.")}
    end
  end

  def handle_event("resolve", %{"choice" => choice}, socket) when choice in ["local", "remote"] do
    result =
      if socket.assigns.event && socket.assigns.event.resource_id,
        do:
          Outbound.resolve(
            socket.assigns.event.resource_id,
            if(choice == "local", do: :local, else: :remote)
          )

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conflict choice saved for the full calendar resource.")
         |> push_patch(
           to:
             if(socket.assigns.event.deleted_at && choice == "local",
               do: ~p"/calendars/#{socket.assigns.calendar.id}",
               else:
                 ~p"/calendars/#{socket.assigns.calendar.id}/events/#{socket.assigns.event.id}"
             )
         )}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Unable to resolve this conflict. Synchronize and try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="calendars-page" class="space-y-6">
      <div class="settings-heading">
        <div>
          <h1>Calendars</h1><p class="settings-intro">
            Local calendars with asynchronous iCloud synchronization.
          </p>
        </div>
        <div class="flex gap-4">
          <.dm_btn id="new-calendar" patch={~p"/calendars/new"} variant="primary">
            Add calendar
          </.dm_btn><.dm_btn navigate={~p"/settings/accounts"} variant="outline">
            Manage Accounts
          </.dm_btn>
        </div>
      </div>
      <p id="calendar-recurrence-help" class="text-on-surface-variant">
        Recurring events retain their original rules and exceptions. This view lists stored records; it does not expand recurring occurrences.
      </p>
      <p :if={@calendars == []} id="calendars-empty">
        No calendars yet. Add a local calendar or configure iCloud inside an Account.
      </p>
      <nav :if={@calendars != []} aria-label="Calendar selection" class="flex flex-wrap gap-4">
        <.link
          :for={calendar <- @calendars}
          id={"calendar-#{calendar.id}"}
          patch={~p"/calendars/#{calendar.id}"}
          aria-current={@calendar && @calendar.id == calendar.id && "page"}
          class="text-primary"
        >{calendar.name} · {source(calendar)}</.link>
      </nav>
      <section
        :if={@calendar_form}
        id="calendar-editor"
        class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-4 space-y-4"
      >
        <h2>{if @live_action == :edit_calendar, do: "Edit calendar", else: "New calendar"}</h2>
        <.form
          for={@calendar_form}
          id="calendar-form"
          phx-change="validate-calendar"
          phx-submit="save-calendar"
          class="space-y-4"
        >
          <.dm_input field={@calendar_form[:name]} label="Calendar name" required />
          <.dm_select
            field={@calendar_form[:account_id]}
            label="Account"
            options={account_options(@accounts)}
          />
          <.dm_select
            field={@calendar_form[:collection_id]}
            label="iCloud calendar"
            options={[
              {"", "Local only — no destination"}
              | Enum.map(@destinations, &{&1.id, &1.name || &1.href})
            ]}
          />
          <.dm_input field={@calendar_form[:sync_to_icloud]} type="checkbox" label="Sync to iCloud" />
          <div :if={occupied_destination?(assigns)} class="space-y-4">
            <.dm_input
              field={@calendar_form[:merge_destination]}
              id="calendar-merge-destination"
              type="checkbox"
              label="Merge the existing local calendar for this iCloud destination"
            />
            <p>
              Its event records will move into this calendar and the replaced local calendar will be removed. Existing iCloud events are retained; your local events will be queued for synchronization.
            </p>
          </div>
          <p :if={@error} role="alert" class="settings-error">{@error}</p>
          <div class="flex gap-4">
            <.dm_btn id="save-calendar" type="submit" variant="primary">Save calendar</.dm_btn><.dm_btn
              patch={~p"/calendars"}
              variant="ghost"
            >
              Cancel
            </.dm_btn>
          </div>
        </.form>
      </section>
      <div :if={@calendar && !@calendar_form} class="grid gap-6 lg:grid-cols-2">
        <section
          class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-4 space-y-4"
          aria-label="Event records"
        >
          <h2>{@calendar.name}</h2><p>{source(@calendar)}</p>
          <div class="flex flex-wrap gap-4">
            <.dm_btn
              :if={editable?(@calendar, :create)}
              id="new-event"
              patch={~p"/calendars/#{@calendar.id}/events/new"}
              variant="outline"
            >
              Add event
            </.dm_btn><.dm_btn
              id="edit-calendar"
              patch={~p"/calendars/#{@calendar.id}/edit"}
              variant="outline"
            >
              Edit calendar
            </.dm_btn><.dm_btn
              id="delete-calendar"
              variant="error"
              confirm="Delete this empty local calendar? Its iCloud calendar is retained."
              phx-click="delete-calendar"
            >
              Delete local calendar
            </.dm_btn>
          </div>
          <p :if={@events == []} id="calendar-events-empty">No event records in this calendar.</p>
          <ul id="calendar-events" class="space-y-4">
            <li :for={event <- @events} id={"event-#{event.id}"}>
              <.link
                patch={~p"/calendars/#{@calendar.id}/events/#{event.id}"}
                class="text-primary font-semibold"
              >{event.summary || "Untitled event"}</.link>
              <p>{event_time(event.starts_at)} <span :if={event.all_day}>· All day</span></p>
              <p :if={event.deleted_at}>Deletion conflict</p>
              <p :if={event.timezone} class="text-sm text-on-surface-variant">{event.timezone}</p>
              <p :if={event.recurrence_rules != []}>Recurring record</p><p :if={
                event.recurrence_id != ""
              }>
                Recurrence exception
              </p>
            </li>
          </ul>
          <div class="flex gap-4">
            <.dm_btn
              id="events-previous"
              type="button"
              variant="ghost"
              phx-click="page"
              phx-value-direction="previous"
              disabled={@offset == 0}
            >
              Previous
            </.dm_btn><.dm_btn
              id="events-next"
              type="button"
              variant="ghost"
              phx-click="page"
              phx-value-direction="next"
              disabled={length(@events) < 50}
            >
              Next
            </.dm_btn>
          </div>
        </section>
        <section
          :if={@event_form}
          id="event-editor"
          class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-4 space-y-4"
        >
          <h2>{if @live_action == :edit_event, do: "Edit stored component", else: "New event"}</h2>
          <.form
            for={@event_form}
            id="event-form"
            phx-change="validate-event"
            phx-submit="save-event"
            class="space-y-4"
          >
            <.dm_input field={@event_form[:summary]} label="Summary" />
            <.dm_input
              field={@event_form[:starts_at]}
              label="Start"
              type={if all_day?(@event_form[:all_day].value), do: "date", else: "datetime-local"}
              required
            />
            <.dm_input
              field={@event_form[:ends_at]}
              label="End"
              type={if all_day?(@event_form[:all_day].value), do: "date", else: "datetime-local"}
            />
            <.dm_input field={@event_form[:all_day]} type="checkbox" label="All day" />
            <.dm_input
              field={@event_form[:timezone]}
              label="Time zone"
              helper="Leave blank for floating local time. Use UTC or a named time zone such as Europe/London."
            />
            <.dm_input field={@event_form[:location]} label="Location" />
            <.dm_input field={@event_form[:description]} type="textarea" label="Description" />
            <p :if={@event && @event.recurrence_id != ""}>
              This edits the stored exception only. The remaining series is preserved.
            </p>
            <p :if={@error} role="alert" class="settings-error">{@error}</p>
            <div class="flex gap-4">
              <.dm_btn id="save-event" type="submit" variant="primary">Save event</.dm_btn><.dm_btn
                patch={~p"/calendars/#{@calendar.id}"}
                variant="ghost"
              >
                Cancel
              </.dm_btn>
            </div>
          </.form>
        </section>
        <section
          :if={@event && !@event_form}
          id="calendar-event-detail"
          class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-4 space-y-4"
        >
          <h2>{@event.summary || "Untitled event"}</h2><p>
            {source(@calendar)} <span :if={!editable?(@calendar, :update)}>· Read-only</span>
          </p>
          <p id="event-sync-status" aria-live="polite">{sync_status(@event, @calendar)}</p>
          <p :if={@event.deleted_at}>Local deletion is waiting for conflict resolution.</p>
          <div :if={conflicted?(@event)} id="event-conflict" class="space-y-4">
            <p>
              Both sides changed. This choice applies to the complete calendar resource, including its stored components.
            </p><.dm_btn
              id="event-use-local"
              phx-click="resolve"
              phx-value-choice="local"
              variant="outline"
            >
              Use local
            </.dm_btn><.dm_btn
              id="event-use-icloud"
              phx-click="resolve"
              phx-value-choice="remote"
              variant="outline"
            >
              Use iCloud
            </.dm_btn>
          </div>
          <dl class="space-y-4">
            <div>
              <dt>Start</dt><dd>{event_time(@event.starts_at)}</dd>
            </div><div>
              <dt>End</dt><dd>{event_time(@event.ends_at)}</dd>
            </div>
            <div>
              <dt>Time zone</dt><dd>{@event.timezone || "Floating / unspecified"}</dd>
            </div><div>
              <dt>All day</dt><dd>{if @event.all_day, do: "Yes", else: "No"}</dd>
            </div>
            <div :if={@event.location}>
              <dt>Location</dt><dd>{@event.location}</dd>
            </div><div :if={@event.description}>
              <dt>Description</dt><dd class="whitespace-pre-wrap">{@event.description}</dd>
            </div>
            <div :if={@event.recurrence_rules != []}>
              <dt>Recurrence rules</dt><dd :for={rule <- @event.recurrence_rules}>{rule}</dd>
            </div>
            <div :if={@event.recurrence_id != ""}>
              <dt>Recurrence exception ID</dt><dd>{@event.recurrence_id}</dd>
            </div><div :if={@event.excluded_dates != []}>
              <dt>Excluded dates</dt><dd :for={date <- @event.excluded_dates}>{date}</dd>
            </div>
          </dl>
          <div
            :if={editable?(@calendar, :update) && is_nil(@event.deleted_at)}
            class="flex flex-wrap gap-4"
          >
            <.dm_btn
              id="edit-event"
              patch={~p"/calendars/#{@calendar.id}/events/#{@event.id}/edit"}
              variant="outline"
            >
              Edit component
            </.dm_btn>
            <.dm_btn
              id="delete-event-component"
              phx-click="delete-event"
              phx-value-scope="component"
              confirm="Delete this stored event component? Remaining components are preserved."
              variant="error"
            >
              Delete component
            </.dm_btn>
            <.dm_btn
              :if={@event.recurrence_rules != [] || @event.recurrence_id != ""}
              id="delete-event-series"
              phx-click="delete-event"
              phx-value-scope="series"
              confirm="Delete the whole stored series, including its exceptions?"
              variant="error"
            >
              Delete whole series
            </.dm_btn>
          </div>
          <.form
            :if={is_nil(@event.deleted_at)}
            for={%{"calendar_id" => ""}}
            as={:copy}
            id="event-copy-form"
            phx-submit="copy-event"
            class="space-y-4"
          >
            <.dm_select
              name="copy[calendar_id]"
              id="event-copy-calendar"
              label="Copy to local calendar"
              options={Enum.map(@calendars, &{&1.id, &1.name})}
              value=""
            />
            <.dm_btn id="copy-event" type="submit" variant="outline">Make local copy</.dm_btn>
          </.form>
        </section>
      </div>
    </section>
    """
  end

  defp calendar_form(socket, calendar) do
    values = Map.new(@calendar_fields, &{&1, Map.get(calendar, String.to_existing_atom(&1))})
    values = Map.put(values, "merge_destination", false)

    assign(socket,
      calendar_form: to_form(values, as: :calendar),
      destinations: destinations(calendar.account_id)
    )
  end

  defp event_form(socket, event) do
    values = Map.new(@event_fields, &{&1, Map.get(event, String.to_existing_atom(&1))})

    values =
      values |> Map.update!("starts_at", &input_time/1) |> Map.update!("ends_at", &input_time/1)

    assign(socket, :event_form, to_form(values, as: :event))
  end

  defp account_options(accounts),
    do: [
      {"", "Local only — no Account"} | Enum.map(accounts, &{&1.id, Accounts.account_address(&1)})
    ]

  defp occupied_destination?(assigns) do
    collection_id = assigns.calendar_form[:collection_id].value
    account_id = assigns.calendar_form[:account_id].value

    Enum.any?(assigns.calendars, fn calendar ->
      not is_nil(collection_id) and calendar.collection_id == collection_id and
        calendar.account_id == account_id and
        (assigns.live_action != :edit_calendar or calendar.id != assigns.calendar.id)
    end)
  end

  defp destinations(account_id) when account_id in [nil, ""], do: []

  defp destinations(account_id) do
    if connection = ICloud.for_account(account_id),
      do: ICloud.collections(connection.id, "calendars"),
      else: []
  end

  defp editable?(%{sync_to_icloud: false}, _operation), do: true
  defp editable?(%{collection_id: nil}, _operation), do: true

  defp editable?(%{collection: collection}, operation) do
    capability =
      Map.get(
        collection,
        %{create: :can_create, update: :can_update, delete: :can_delete}[operation]
      )

    capability == true or (is_nil(capability) and collection.writable)
  end

  defp source(%{collection_id: nil}), do: "Local calendar"
  defp source(%{collection: collection}), do: "iCloud · #{collection.connection.apple_id}"
  defp conflicted?(%{resource: %{status: "conflict"}}), do: true
  defp conflicted?(_), do: false
  defp sync_status(_event, %{sync_to_icloud: false}), do: "Sync to iCloud is off"
  defp sync_status(%{resource: %{status: "synced"}}, _calendar), do: "Synchronized"

  defp sync_status(%{resource: %{status: "uncertain"}}, _calendar),
    do: "Syncing — confirming remote outcome"

  defp sync_status(%{resource: %{status: status}}, _calendar), do: String.capitalize(status)
  defp sync_status(_event, %{account_id: nil}), do: "Local only"
  defp sync_status(_, _), do: "Waiting for configuration"

  defp normalize_event(attrs) do
    attrs =
      Map.new(attrs, fn {key, value} ->
        {key,
         if(value == "" and key in ["ends_at", "timezone", "location", "description"],
           do: nil,
           else: value
         )}
      end)

    date_only = all_day?(attrs["all_day"])
    attrs = if date_only, do: Map.put(attrs, "timezone", nil), else: attrs

    Enum.reduce(["starts_at", "ends_at"], attrs, fn key, result ->
      Map.update(result, key, nil, &stored_time(&1, date_only, attrs["timezone"]))
    end)
  end

  defp all_day?(value), do: value in [true, "true"]
  defp stored_time(nil, _, _), do: nil

  defp stored_time(value, date_only, timezone) do
    value = String.replace(value, ["-", ":"], "")
    value = if byte_size(value) == 13, do: value <> "00", else: value

    cond do
      date_only -> String.slice(value, 0, 8)
      timezone == "UTC" and not String.ends_with?(value, "Z") -> value <> "Z"
      true -> value
    end
  end

  defp input_time(nil), do: nil

  defp input_time(
         <<year::binary-size(4), month::binary-size(2), day::binary-size(2), "T",
           hour::binary-size(2), minute::binary-size(2), second::binary-size(2), _suffix::binary>>
       ),
       do: "#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}"

  defp input_time(<<year::binary-size(4), month::binary-size(2), day::binary-size(2)>>),
    do: "#{year}-#{month}-#{day}"

  defp input_time(value), do: value

  defp event_time(nil), do: "Not specified"

  defp event_time(<<year::binary-size(4), month::binary-size(2), day::binary-size(2)>>),
    do: "#{year}-#{month}-#{day}"

  defp event_time(
         <<year::binary-size(4), month::binary-size(2), day::binary-size(2), "T",
           hour::binary-size(2), minute::binary-size(2), second::binary-size(2), suffix::binary>>
       )
       when suffix in ["", "Z"],
       do:
         "#{year}-#{month}-#{day} #{hour}:#{minute}:#{second}" <>
           if(suffix == "Z", do: " UTC", else: "")

  defp event_time(value), do: value
end

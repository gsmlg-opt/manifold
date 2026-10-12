defmodule ManifoldWeb.CalendarLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.{Accounts, Calendars}
  alias Manifold.Connectors.ICloud
  alias Manifold.Connectors.ICloud.Outbound
  alias Manifold.Data.Schema.{Calendar, CalendarEvent}
  alias ManifoldWeb.CalendarLive.Display

  @calendar_fields ~w(name account_id collection_id sync_to_icloud merge_destination)
  @event_fields ~w(summary description location starts_at ends_at timezone all_day)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Calendars",
       selected_date: Date.utc_today(),
       today: Date.utc_today(),
       display_view: "month",
       navigation_open: false,
       days: [],
       agenda: [],
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

    selected_date = selected_date(params["date"], event, socket.assigns.selected_date)
    days = Display.month_days(selected_date)

    display_view =
      if params["view"] in ["month", "agenda"],
        do: params["view"],
        else: socket.assigns.display_view

    events =
      if calendar,
        do:
          Calendars.list_events_in_range(calendar.id, hd(days), Date.add(List.last(days), 1),
            include_deleted_conflicts: true
          ),
        else: []

    socket =
      assign(socket,
        calendars: calendars,
        calendar: calendar,
        event: event,
        selected_date: selected_date,
        days: days,
        display_view: display_view,
        events: events,
        agenda: Display.agenda(events, selected_date),
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
        {:noreply,
         event_form(socket, %CalendarEvent{
           starts_at: Elixir.Calendar.strftime(selected_date, "%Y%m%d") <> "T090000"
         })}

      socket.assigns.live_action == :edit_event && editable?(calendar, :update) ->
        {:noreply, event_form(socket, event)}

      socket.assigns.live_action == :edit_event ->
        {:noreply,
         socket
         |> put_flash(:error, "This iCloud source is read-only. Make a local copy to edit it.")
         |> push_patch(to: event_path(calendar, event, socket.assigns))}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle-navigation", _params, socket),
    do: {:noreply, assign(socket, :navigation_open, !socket.assigns.navigation_open)}

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
         |> push_patch(to: calendar_path(calendar, socket.assigns))}

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
         socket
         |> put_flash(:info, "Local calendar deleted.")
         |> push_patch(to: calendar_path(nil, socket.assigns))}

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
         |> push_patch(to: event_path(socket.assigns.calendar, event, socket.assigns))}

      _ ->
        {:noreply,
         assign(socket,
           event_form: to_form(Map.take(params, @event_fields), as: :event),
           error: "Unable to save event. Check its dates and source permissions."
         )}
    end
  end

  def handle_event("validate-event", %{"event" => params}, socket) do
    params = Map.take(params, @event_fields)
    params = Map.put_new(params, "timezone", socket.assigns.event_form.params["timezone"])

    params =
      Enum.reduce(["starts_at", "ends_at"], params, fn field, attrs ->
        Map.update(attrs, field, nil, &input_date_mode(&1, all_day?(params["all_day"])))
      end)

    {:noreply, assign(socket, event_form: to_form(params, as: :event), error: nil)}
  end

  def handle_event("delete-event", %{"scope" => scope}, socket)
      when scope in ["component", "series"] do
    case socket.assigns.event &&
           Calendars.delete_event(socket.assigns.event.id, whole_series: scope == "series") do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Event deletion saved locally.")
         |> push_patch(to: calendar_path(socket.assigns.calendar, socket.assigns))}

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
         |> push_patch(
           to: event_path(Calendars.get_calendar(event.calendar_id), event, socket.assigns)
         )}

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
               do: calendar_path(socket.assigns.calendar, socket.assigns),
               else: event_path(socket.assigns.calendar, socket.assigns.event, socket.assigns)
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
    <section
      id="calendars-page"
      class={[
        "calendar-workspace",
        (@event || @event_form || @calendar_form) && "has-calendar-drawer"
      ]}
    >
      <aside
        class={["calendar-sidebar", @navigation_open && "is-open"]}
        aria-label="Calendar navigation"
      >
        <div class="calendar-sidebar-heading">
          <.dm_mdi name="calendar-outline" class="w-6 h-6" />
          <h1>Calendar</h1>
        </div>
        <.dm_btn
          :if={@calendar && editable?(@calendar, :create) && !@event_form && !@calendar_form}
          id="new-event"
          patch={new_event_path(@calendar, assigns, @selected_date)}
          variant="primary"
          class="calendar-create"
        >
          <.dm_mdi name="plus" class="w-5 h-5" /> Create event
        </.dm_btn>
        <.dm_btn
          :if={!@calendar && !@calendar_form}
          id="new-calendar"
          patch={new_calendar_path(assigns)}
          variant="primary"
          class="calendar-create"
        >
          <.dm_mdi name="plus" class="w-5 h-5" /> Add calendar
        </.dm_btn>
        <div class="calendar-mini" aria-label="Mini month">
          <div class="calendar-mini-heading">
            <span>{Elixir.Calendar.strftime(@selected_date, "%B %Y")}</span>
            <.link
              patch={month_path(assigns, -1)}
              aria-label="Previous month"
              class="calendar-icon-link"
            ><.dm_mdi name="chevron-left" class="w-4 h-4" /></.link>
            <.link patch={month_path(assigns, 1)} aria-label="Next month" class="calendar-icon-link"><.dm_mdi
              name="chevron-right"
              class="w-4 h-4"
            /></.link>
          </div>
          <div class="calendar-mini-grid">
            <span :for={weekday <- ~w(M T W T F S S)} class="calendar-mini-weekday" aria-hidden="true">{weekday}</span>
            <.link
              :for={day <- @days}
              patch={calendar_path(@calendar, assigns, day)}
              aria-label={Elixir.Calendar.strftime(day, "%A, %B %-d, %Y")}
              aria-current={day == @selected_date && "date"}
              class={[
                "calendar-mini-day",
                day.month != @selected_date.month && "outside-month",
                day == @selected_date && "is-selected",
                day == @today && "is-today"
              ]}
            >{day.day}</.link>
          </div>
        </div>
        <div class="calendar-source-heading">
          <h2>My calendars</h2><.link
            :if={@calendar}
            id="new-calendar"
            patch={new_calendar_path(assigns)}
            aria-label="Add calendar"
            class="calendar-icon-link"
          ><.dm_mdi name="plus" class="w-5 h-5" /></.link>
        </div>
        <nav aria-label="Calendar selection" class="calendar-sources">
          <.link
            :for={calendar <- @calendars}
            id={"calendar-#{calendar.id}"}
            patch={calendar_path(calendar, assigns)}
            aria-current={@calendar && @calendar.id == calendar.id && "page"}
            class={["calendar-source", @calendar && @calendar.id == calendar.id && "is-selected"]}
          >
            <span class={"calendar-source-dot tone-#{calendar_tone(calendar)}"}></span>
            <span><strong>{calendar.name}</strong><small>{if calendar.collection_id,
              do: "iCloud",
              else: "On this device"}</small></span>
            <.dm_mdi :if={@calendar && @calendar.id == calendar.id} name="check" class="w-4 h-4" />
          </.link>
        </nav>
        <div class="calendar-sidebar-footer">
          <.link navigate={~p"/settings/accounts"}><.dm_mdi name="cloud-outline" class="w-4 h-4" />
          Manage Accounts</.link>
          <p>Local calendars. Optional iCloud sync.</p>
        </div>
      </aside>
      <div class="calendar-main">
        <header class="calendar-toolbar">
          <%!-- # TODO(upstream): duskmoon-dev/duskmoon-elements#86 --%>
          <%!-- # WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#86 — slotted text names the internal button. --%>
          <.dm_btn
            id="calendar-navigation-toggle"
            variant="ghost"
            phx-click="toggle-navigation"
            aria-label="Toggle calendar navigation"
            aria-expanded={@navigation_open}
            class="calendar-mobile-toggle"
          >
            <.dm_mdi name="menu" class="w-5 h-5" />
            <span class="sr-only">{if @navigation_open,
              do: "Close calendar navigation",
              else: "Open calendar navigation"}</span>
          </.dm_btn>
          <.dm_btn
            id="calendar-today"
            patch={calendar_path(@calendar, assigns, @today)}
            variant="outline"
            size="sm"
          >
            Today
          </.dm_btn>
          <div class="calendar-month-controls">
            <.link
              id="calendar-previous-month"
              patch={month_path(assigns, -1)}
              aria-label="Previous month"
              class="calendar-icon-link"
            ><.dm_mdi name="chevron-left" class="w-5 h-5" /></.link>
            <.link
              id="calendar-next-month"
              patch={month_path(assigns, 1)}
              aria-label="Next month"
              class="calendar-icon-link"
            ><.dm_mdi name="chevron-right" class="w-5 h-5" /></.link>
          </div>
          <h2 id="calendar-month-title">
            {Elixir.Calendar.strftime(@selected_date, "%B")}
            <span>{Elixir.Calendar.strftime(@selected_date, "%Y")}</span>
          </h2>
          <.dm_btn
            :if={
              @calendar && editable?(@calendar, :create) && !@navigation_open && !@event_form &&
                !@calendar_form
            }
            id="new-event-mobile"
            patch={new_event_path(@calendar, assigns, @selected_date)}
            variant="primary"
            size="sm"
            aria-label="Create event"
            class="calendar-mobile-create"
          >
            <.dm_mdi name="plus" class="w-5 h-5" />
          </.dm_btn>
          <.dm_btn
            :if={!@calendar && !@navigation_open && !@calendar_form}
            id="new-calendar-mobile"
            patch={new_calendar_path(assigns)}
            variant="primary"
            size="sm"
            aria-label="Add calendar"
            class="calendar-mobile-create"
          >
            <.dm_mdi name="plus" class="w-5 h-5" />
          </.dm_btn>
          <span class="calendar-mobile-view-label">Monthly agenda</span>
          <div class="calendar-view-switch" aria-label="Calendar view">
            <.link
              id="calendar-month-view"
              patch={calendar_path(@calendar, assigns, @selected_date, "month")}
              aria-current={@display_view == "month" && "page"}
            >Month</.link>
            <.link
              id="calendar-agenda-view"
              patch={calendar_path(@calendar, assigns, @selected_date, "agenda")}
              aria-current={@display_view == "agenda" && "page"}
            >Agenda</.link>
          </div>
        </header>
        <div :if={@calendar} class="calendar-contextbar">
          <span class={"calendar-source-dot tone-#{calendar_tone(@calendar)}"}></span><strong>{@calendar.name}</strong>
          <span class="calendar-context-source">{source(@calendar)}</span>
          <.dm_btn
            id="edit-calendar"
            patch={edit_calendar_path(@calendar, assigns)}
            variant="ghost"
            size="sm"
            aria-label="Edit calendar"
          >
            <.dm_mdi name="cog-outline" class="w-4 h-4" />
          </.dm_btn>
        </div>
        <div :if={!@calendar} id="calendars-empty" class="calendar-empty-state">
          <.dm_mdi name="calendar-blank-outline" class="w-12 h-12" />
          <h2>A little room for your plans.</h2>
          <p>No calendars yet. Add a local calendar or configure iCloud inside an Account.</p>
        </div>
        <div
          :if={@calendar}
          id="calendar-events"
          class={["calendar-canvas", @display_view == "month" && "is-month"]}
        >
          <div
            :if={@display_view == "month"}
            id="calendar-month-grid"
            class="calendar-month-grid"
            aria-label="Month calendar"
          >
            <div
              :for={weekday <- ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday)}
              class="calendar-weekday"
            >
              {String.slice(weekday, 0, 3)}
            </div>
            <div
              :for={day <- @days}
              id={"calendar-day-#{Date.to_iso8601(day)}"}
              class={[
                "calendar-day",
                day.month != @selected_date.month && "outside-month",
                day == @today && "is-today",
                day == @selected_date && "is-selected"
              ]}
            >
              <.link
                patch={
                  if editable?(@calendar, :create),
                    do: new_event_path(@calendar, assigns, day),
                    else: calendar_path(@calendar, assigns, day)
                }
                class="calendar-day-number"
                aria-label={Elixir.Calendar.strftime(day, "%A, %B %-d, %Y") <> if(editable?(@calendar, :create), do: ", create event", else: "")}
              >{day.day}</.link>
              <ul class="calendar-day-events">
                <li
                  :for={event <- events_on_day(@events, day)}
                  id={month_event_id(event, day, hd(@days))}
                >
                  <.link
                    patch={event_path(@calendar, event, assigns)}
                    class={[
                      "calendar-event",
                      "tone-#{calendar_tone(@calendar)}",
                      event.all_day && "is-all-day",
                      @event && @event.id == event.id && "is-selected"
                    ]}
                    title={(event.summary || "Untitled event") <> if(event.all_day, do: " · All day", else: " · " <> (event.timezone || "Floating time"))}
                  >
                    <span :if={!event.all_day} class="calendar-event-dot"></span><time>{Display.clock(
                      event
                    )}</time><strong>{event.summary || "Untitled event"}</strong>
                    <.dm_mdi :if={Display.recurring?(event)} name="repeat" class="w-3 h-3" />
                    <span :if={event.deleted_at} class="calendar-event-conflict">Deletion conflict</span>
                  </.link>
                </li>
              </ul>
            </div>
          </div>
          <div
            id="calendar-agenda"
            class={["calendar-agenda", @display_view == "month" && "mobile-agenda"]}
          >
            <p :if={@agenda == []} id="calendar-events-empty" class="calendar-agenda-empty">
              No event records this month. Make room for something good.
            </p>
            <section
              :for={{day, events} <- @agenda}
              class="calendar-agenda-day"
              aria-label={Elixir.Calendar.strftime(day, "%A, %B %-d")}
            >
              <div class={[
                "calendar-agenda-date",
                day == @today && "is-today",
                day == @selected_date && "is-selected"
              ]}>
                <span>{Elixir.Calendar.strftime(day, "%a")}</span><strong>{day.day}</strong>
              </div>
              <ul>
                <li
                  :for={event <- events}
                  id={
                    if @display_view == "agenda",
                      do: "event-#{event.id}",
                      else: "agenda-event-#{event.id}"
                  }
                >
                  <.link patch={event_path(@calendar, event, assigns)} class="calendar-agenda-event">
                    <span class="calendar-agenda-time">{Display.clock(event)}</span>
                    <span class={"calendar-source-dot tone-#{calendar_tone(@calendar)}"}></span>
                    <span class="calendar-agenda-summary"><strong>{event.summary || "Untitled event"}</strong><small :if={
                      event.location
                    }>{event.location}</small><small :if={!event.all_day} class="calendar-agenda-zone">{event.timezone ||
                      "Floating time"}</small><small :if={
                      Date.compare(Display.date(event.starts_at), day) == :lt
                    }>Continues from {event_time(event.starts_at)}</small><small :if={
                      event.deleted_at
                    }>Deletion conflict</small></span>
                    <.dm_mdi :if={Display.recurring?(event)} name="repeat" class="w-4 h-4" />
                  </.link>
                </li>
              </ul>
            </section>
          </div>
        </div>
        <footer class="calendar-canvas-footer">
          <p id="calendar-recurrence-help">
            <.dm_mdi name="repeat" class="w-4 h-4" />
            Stored records only · this view does not expand recurring occurrences. Original rules and exceptions are retained.
          </p>
          <span :if={@calendar} id="calendar-timezone-help">Times shown as stored · {calendar_timezones(
            @events
          )}</span>
        </footer>
      </div>
      <section
        :if={@calendar_form}
        id="calendar-editor"
        class="calendar-drawer calendar-editor"
      >
        <.drawer_close context={assigns} />
        <p class="calendar-eyebrow">Calendar settings</p>
        <h2>{if @live_action == :edit_calendar, do: "Edit calendar", else: "New calendar"}</h2>
        <p class="calendar-drawer-intro">
          Choose where this calendar lives and what syncs to iCloud.
        </p>
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
              patch={calendar_path(@calendar, assigns)}
              variant="ghost"
            >
              Cancel
            </.dm_btn>
          </div>
        </.form>
        <.dm_btn
          :if={@live_action == :edit_calendar}
          id="delete-calendar"
          variant="error"
          confirm="Delete this empty local calendar? Its iCloud calendar is retained."
          phx-click="delete-calendar"
        >
          Delete local calendar
        </.dm_btn>
      </section>
      <section
        :if={@event_form}
        id="event-editor"
        class="calendar-drawer calendar-editor"
      >
        <.drawer_close context={assigns} />
        <p class="calendar-eyebrow">Event</p>
        <h2>{if @live_action == :edit_event, do: "Edit event", else: "New event"}</h2>
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
            helper={
              if all_day?(@event_form[:all_day].value),
                do: "End date is exclusive. For one day, use the following date.",
                else: nil
            }
            type={if all_day?(@event_form[:all_day].value), do: "date", else: "datetime-local"}
          />
          <.dm_input field={@event_form[:all_day]} type="checkbox" label="All day" />
          <.dm_input
            field={@event_form[:timezone]}
            label="Time zone"
            disabled={all_day?(@event_form[:all_day].value)}
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
              patch={calendar_path(@calendar, assigns)}
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
        class="calendar-drawer calendar-detail"
      >
        <.drawer_close context={assigns} />
        <p class="calendar-eyebrow">
          {Elixir.Calendar.strftime(Display.date(@event.starts_at) || @selected_date, "%A, %B %-d")}
        </p>
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
        <dl class="calendar-detail-fields">
          <div>
            <dt>Start</dt><dd>{event_time(@event.starts_at)}</dd>
          </div><div>
            <dt>{if @event.all_day, do: "End (exclusive)", else: "End"}</dt><dd>
              {event_time(@event.ends_at)}
            </dd>
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
            patch={edit_event_path(@calendar, @event, assigns)}
            variant="outline"
          >
            Edit event
          </.dm_btn>
          <.dm_btn
            id="delete-event-component"
            phx-click="delete-event"
            phx-value-scope="component"
            confirm="Delete this stored event component? Remaining components are preserved."
            variant="error"
          >
            {if Display.recurring?(@event), do: "Delete component", else: "Delete event"}
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
          class="calendar-copy-form"
        >
          <.dm_select
            name="copy[calendar_id]"
            id="event-copy-calendar"
            label="Copy to local calendar"
            options={Enum.map(Enum.filter(@calendars, &editable?(&1, :create)), &{&1.id, &1.name})}
            value=""
          />
          <.dm_btn id="copy-event" type="submit" variant="outline">Make local copy</.dm_btn>
        </.form>
      </section>
    </section>
    """
  end

  attr :context, :map, required: true

  defp drawer_close(assigns) do
    ~H"""
    <.link
      id="calendar-drawer-close"
      patch={calendar_path(@context.calendar, @context)}
      aria-label="Close details"
      class="calendar-drawer-close"
    ><.dm_mdi name="close" class="w-5 h-5" /></.link>
    """
  end

  defp selected_date(value, event, fallback) do
    case value && Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> if(event, do: Display.date(event.starts_at) || fallback, else: fallback)
    end
  end

  defp calendar_path(calendar, assigns, date \\ nil, view \\ nil) do
    params = %{
      date: Date.to_iso8601(date || assigns.selected_date),
      view: view || assigns.display_view
    }

    if calendar, do: ~p"/calendars/#{calendar.id}?#{params}", else: ~p"/calendars?#{params}"
  end

  defp month_path(assigns, direction),
    do:
      calendar_path(
        assigns.calendar,
        assigns,
        Display.shift_month(assigns.selected_date, direction)
      )

  defp new_calendar_path(assigns),
    do:
      ~p"/calendars/new?#{%{date: Date.to_iso8601(assigns.selected_date), view: assigns.display_view}}"

  defp new_event_path(calendar, assigns, date),
    do:
      ~p"/calendars/#{calendar.id}/events/new?#{%{date: Date.to_iso8601(date), view: assigns.display_view}}"

  defp event_path(calendar, event, assigns),
    do:
      ~p"/calendars/#{calendar.id}/events/#{event.id}?#{%{date: Date.to_iso8601(assigns.selected_date), view: assigns.display_view}}"

  defp edit_event_path(calendar, event, assigns),
    do:
      ~p"/calendars/#{calendar.id}/events/#{event.id}/edit?#{%{date: Date.to_iso8601(assigns.selected_date), view: assigns.display_view}}"

  defp edit_calendar_path(calendar, assigns),
    do:
      ~p"/calendars/#{calendar.id}/edit?#{%{date: Date.to_iso8601(assigns.selected_date), view: assigns.display_view}}"

  defp calendar_timezones(events) do
    events
    |> Enum.reject(& &1.all_day)
    |> Enum.map(&(&1.timezone || "Floating time"))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(" / ")
    |> case do
      "" -> "All-day dates"
      zones -> zones
    end
  end

  defp calendar_tone(calendar), do: if(calendar.collection_id, do: "primary", else: "tertiary")
  defp events_on_day(events, date), do: Enum.filter(events, &Display.on_day?(&1, date))

  defp month_event_id(event, day, first) do
    start = Display.date(event.starts_at)
    visible_start = if Date.compare(start, first) == :lt, do: first, else: start

    if day == visible_start,
      do: "event-#{event.id}",
      else: "event-#{event.id}-#{Date.to_iso8601(day)}"
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

  defp input_date_mode(value, true) when is_binary(value), do: String.slice(value, 0, 10)
  defp input_date_mode(<<date::binary-size(10)>>, false), do: date <> "T09:00:00"
  defp input_date_mode(value, _), do: value

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

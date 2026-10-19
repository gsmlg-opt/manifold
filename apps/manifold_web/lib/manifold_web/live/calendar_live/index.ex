defmodule ManifoldWeb.CalendarLive.Index do
  use ManifoldWeb, :live_view
  alias Manifold.Calendars
  alias Manifold.Calendars.Time, as: CalendarTime
  alias Manifold.Connectors.{CalendarConnections, CalendarMigration, CalendarSync}
  alias Manifold.Data.Schema.{CalendarEvent, CalendarEventBinding}
  import Ecto.Query
  alias Manifold.Repo
  alias ManifoldWeb.CalendarLive.Display

  @event_fields ~w(summary description location starts_at ends_at timezone all_day recurrence_rules recurrence_dates excluded_dates)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Manifold.PubSub, "calendar:changes")

    {:ok,
     assign(socket,
       page_title: "Calendars",
       selected_date: Date.utc_today(),
       today: Date.utc_today(),
       display_view: "month",
       viewing_timezone: "Etc/UTC",
       navigation_open: false,
       days: [],
       agenda: [],
       calendars: [],
       visible_ids: nil,
       writer_id: nil,
       calendar: nil,
       occurrences: [],
       event: nil,
       occurrence_slot: "",
       calendar_form: nil,
       event_form: nil,
       error: nil,
       sync_targets: [],
       connections: [],
       discovered: [],
       selected_connection_id: nil,
       enrollment_preview: nil,
       conflict_preview: nil,
       disconnect_preview: nil,
       migration_preview: nil,
       editing_revision: nil,
       event_bindings: [],
       icloud_form: to_form(%{}, as: :icloud)
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    calendars = Calendars.list_calendars()

    calendar =
      if params["calendar_id"],
        do: Enum.find(calendars, &(&1.id == params["calendar_id"])),
        else: List.first(calendars)

    event = if params["id"], do: Calendars.get_event(params["id"])
    event = if event && calendar && event.calendar_id == calendar.id, do: event

    selected =
      parse_date(params["date"]) ||
        if(event,
          do: viewed_event_date(event, params["timezone"] || socket.assigns.viewing_timezone)
        ) || socket.assigns.selected_date

    timezone = params["timezone"] || socket.assigns.viewing_timezone
    timezone = if valid_timezone?(timezone), do: timezone, else: socket.assigns.viewing_timezone
    ids = Enum.map(calendars, & &1.id)

    visible =
      if is_nil(socket.assigns.visible_ids),
        do: ids,
        else: Enum.filter(socket.assigns.visible_ids, &(&1 in ids))

    writer =
      if socket.assigns.writer_id in ids,
        do: socket.assigns.writer_id,
        else: calendar && calendar.id

    socket =
      assign(socket,
        calendars: calendars,
        calendar: calendar,
        event: event,
        selected_date: selected,
        viewing_timezone: timezone,
        display_view:
          if(params["view"] in ["month", "agenda"],
            do: params["view"],
            else: socket.assigns.display_view
          ),
        days: Display.month_days(selected),
        visible_ids: visible,
        writer_id: writer,
        occurrence_slot: params["occurrence"] || (event && event.recurrence_id) || "",
        calendar_form: nil,
        event_form: nil,
        error: nil,
        conflict_preview: nil,
        enrollment_preview: nil
      )

    socket = refresh(socket)

    socket =
      case socket.assigns.live_action do
        :new_calendar ->
          assign(socket, calendar_form: to_form(%{"name" => ""}, as: :calendar))

        :edit_calendar when not is_nil(calendar) ->
          assign(socket, calendar_form: to_form(%{"name" => calendar.name}, as: :calendar))

        :new_event when not is_nil(calendar) ->
          event_form(socket, %CalendarEvent{
            starts_at: Calendar.strftime(selected, "%Y%m%d") <> "T090000"
          })

        :edit_event when not is_nil(event) ->
          if event.read_only,
            do:
              put_flash(
                socket,
                :error,
                "This source is read-only. Copy it to a local calendar to edit."
              ),
            else: event_form(socket, event)

        _ ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:calendar_changed, socket), do: {:noreply, refresh(socket)}

  @impl true
  def handle_event("toggle-navigation", _, socket),
    do: {:noreply, assign(socket, navigation_open: !socket.assigns.navigation_open)}

  def handle_event("toggle-calendar", %{"id" => id}, socket) do
    ids = socket.assigns.visible_ids

    visible =
      if id in ids,
        do: List.delete(ids, id),
        else: if(Enum.any?(socket.assigns.calendars, &(&1.id == id)), do: [id | ids], else: ids)

    {:noreply, refresh(assign(socket, visible_ids: visible))}
  end

  def handle_event("set-writer", %{"writer" => %{"calendar_id" => id}}, socket) do
    if Enum.any?(socket.assigns.calendars, &(&1.id == id)),
      do: {:noreply, assign(socket, writer_id: id)},
      else: {:noreply, socket}
  end

  def handle_event("set-timezone", %{"viewing" => %{"timezone" => timezone}}, socket) do
    if valid_timezone?(timezone),
      do: {:noreply, refresh(assign(socket, viewing_timezone: timezone, error: nil))},
      else: {:noreply, assign(socket, error: "Choose a valid IANA viewing time zone.")}
  end

  def handle_event("validate-calendar", %{"calendar" => params}, socket),
    do:
      {:noreply,
       assign(socket, calendar_form: to_form(Map.take(params, ["name"]), as: :calendar))}

  def handle_event("save-calendar", %{"calendar" => params}, socket) do
    attrs = Map.take(params, ["name"])

    result =
      if socket.assigns.live_action == :edit_calendar,
        do: Calendars.update_calendar(socket.assigns.calendar.id, attrs),
        else: Calendars.create_calendar(attrs)

    case result do
      {:ok, calendar} ->
        {:noreply,
         socket
         |> assign(
           visible_ids: Enum.uniq([calendar.id | socket.assigns.visible_ids]),
           writer_id: socket.assigns.writer_id || calendar.id
         )
         |> put_flash(:info, "Calendar saved locally.")
         |> push_patch(to: calendar_path(calendar.id, socket.assigns))}

      _ ->
        {:noreply, assign(socket, error: "Unable to save calendar. Check its name.")}
    end
  end

  def handle_event("delete-calendar", _, socket) do
    case socket.assigns.calendar && Calendars.delete_calendar(socket.assigns.calendar.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Local calendar deleted. Cloud calendars and events are retained.")
         |> push_patch(to: calendar_path(nil, socket.assigns))}

      _ ->
        {:noreply, put_flash(socket, :error, "Unable to delete this calendar.")}
    end
  end

  def handle_event("validate-event", %{"event" => params}, socket) do
    previous = socket.assigns.event_form.params
    merged = Map.merge(previous, Map.take(params, @event_fields))
    all_day = truthy?(merged["all_day"])

    merged =
      Map.update!(merged, "starts_at", &input_mode(&1, all_day))
      |> Map.update!("ends_at", &input_mode(&1, all_day))

    {:noreply, assign(socket, event_form: to_form(merged, as: :event))}
  end

  def handle_event("save-event", %{"event" => params}, socket) do
    attrs =
      socket.assigns.event_form.params
      |> Map.merge(Map.take(params, @event_fields))
      |> normalize_event()
      |> Map.put("calendar_id", socket.assigns.calendar.id)

    event = socket.assigns.event
    slot = socket.assigns.occurrence_slot

    result =
      cond do
        socket.assigns.live_action != :edit_event ->
          Calendars.create_event(attrs)

        slot != "" && Display.recurring?(event) ->
          Calendars.update_occurrence(event.id, slot, attrs,
            expected_revision: socket.assigns.editing_revision
          )

        true ->
          Calendars.update_event(event.id, attrs,
            expected_revision: socket.assigns.editing_revision
          )
      end

    case result do
      {:ok, saved} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Event saved locally. Each confirmed target synchronizes independently."
         )
         |> push_patch(to: event_path(saved, socket.assigns))}

      {:error, :stale} ->
        {:noreply, assign(socket, error: "This event changed. Reopen it before saving.")}

      _ ->
        {:noreply,
         assign(socket, error: "Unable to save event. Check its date, time and recurrence.")}
    end
  end

  def handle_event("delete-event", params, socket) do
    event = socket.assigns.event

    scope =
      if params["scope"] == "series",
        do: :series,
        else: if(Display.recurring?(event), do: :occurrence, else: :event)

    opts = [
      scope: scope,
      recurrence_id: socket.assigns.occurrence_slot,
      expected_revision: event.local_revision
    ]

    case Calendars.delete_event(event.id, opts) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Event deleted locally; enrolled targets retain separate deletion work."
         )
         |> push_patch(to: calendar_path(event.calendar_id, socket.assigns))}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Unable to delete event. Choose an occurrence or the whole series."
         )}
    end
  end

  def handle_event("copy-event", %{"copy" => params}, socket) do
    id = params["calendar_id"]

    uploads =
      Enum.any?(
        Calendars.list_bindings(id),
        &(&1.state in ["active", "paused"] and &1.direction == "bidirectional")
      )

    scope =
      case params["scope"] do
        "series" -> :series
        "occurrence" -> :occurrence
        _ -> :event
      end

    if uploads and not truthy?(params["confirm_upload"]) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Confirm that this destination uploads the new copy to its synchronization targets."
       )}
    else
      case Calendars.copy_event(socket.assigns.event.id, %{calendar_id: id},
             scope: scope,
             recurrence_id: socket.assigns.occurrence_slot
           ) do
        {:ok, copy} ->
          {:noreply,
           socket
           |> put_flash(:info, "Independent copy created.")
           |> push_patch(to: event_path(copy, socket.assigns))}

        _ ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Unable to copy. Choose an explicit series or occurrence scope."
           )}
      end
    end
  end

  def handle_event("binding-action", %{"id" => id, "action" => action}, socket) do
    allowed = Enum.any?(socket.assigns.sync_targets, &(&1.binding.id == id))

    result =
      if allowed do
        case action do
          "pause" -> CalendarSync.pause(id)
          "resume" -> CalendarSync.resume(id)
          "detach" -> CalendarSync.detach(id)
          "reenroll" -> CalendarSync.reenroll_preview(id)
          _ -> {:error, :invalid_action}
        end
      else
        {:error, :not_found}
      end

    case result do
      {:ok, binding} ->
        socket =
          if action == "reenroll", do: assign(socket, enrollment_preview: binding), else: socket

        {:noreply, refresh(socket)}

      _ ->
        {:noreply, put_flash(socket, :error, "Unable to change synchronization target.")}
    end
  end

  def handle_event("discover-calendars", %{"connection" => %{"id" => id}}, socket) do
    case CalendarConnections.discover(id) do
      {:ok, calendars} ->
        {:noreply, assign(socket, discovered: calendars, selected_connection_id: id, error: nil)}

      _ ->
        {:noreply,
         assign(socket,
           error: "Unable to discover calendars. Check the connection authorization."
         )}
    end
  end

  def handle_event("preview-enrollment", %{"remote_id" => id}, socket) do
    remote = Enum.find(socket.assigns.discovered, &(&1.id == id))

    result =
      if remote && socket.assigns.calendar,
        do:
          CalendarSync.preview(
            socket.assigns.calendar.id,
            socket.assigns.selected_connection_id,
            remote
          ),
        else: {:error, :not_found}

    case result do
      {:ok, binding} ->
        {:noreply, assign(socket, enrollment_preview: binding, error: nil)}

      {:error, {:already_bound, _}} ->
        {:noreply,
         assign(socket,
           error:
             "This remote calendar already has a local binding. Open it or explicitly detach its existing binding."
         )}

      _ ->
        {:noreply, assign(socket, error: "Unable to prepare a complete synchronization preview.")}
    end
  end

  def handle_event("confirm-enrollment", %{"enrollment" => params}, socket) do
    binding = socket.assigns.enrollment_preview
    claims = parse_claims(params["claims"] || "")

    selections = %{
      upload_event_ids: List.wrap(params["uploads"]),
      import_resource_ids: List.wrap(params["imports"]),
      claims: claims
    }

    case binding && claims != :invalid &&
           CalendarSync.confirm(binding.id, binding.enrollment_manifest["token"], selections) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(enrollment_preview: nil)
         |> refresh()
         |> put_flash(
           :info,
           "Confirmed selections saved. Imported changes propagate to other confirmed targets."
         )}

      _ ->
        {:noreply,
         assign(socket,
           error: "The preview changed or a selection is invalid. Discover and preview again."
         )}
    end
  end

  def handle_event("preview-conflict", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.event_bindings, &(&1.id == id)) do
      case CalendarSync.conflict_preview(id) do
        {:ok, preview} -> {:noreply, assign(socket, conflict_preview: Map.put(preview, :id, id))}
        _ -> {:noreply, put_flash(socket, :error, "Conflict is no longer available.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("resolve-conflict", %{"choice" => choice}, socket)
      when choice in ["local", "remote"] do
    preview = socket.assigns.conflict_preview

    case preview && CalendarSync.resolve_conflict(preview.id, preview.version, choice) do
      {:ok, _} ->
        {:noreply, socket |> assign(conflict_preview: nil) |> refresh()}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Conflict changed. Preview it again before choosing.")}
    end
  end

  def handle_event("connect-icloud", %{"icloud" => params}, socket) do
    case CalendarConnections.connect_icloud(Map.take(params, ["apple_id", "app_password"])) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(icloud_form: to_form(%{}, as: :icloud))
         |> refresh()
         |> put_flash(:info, "iCloud Calendar connected. Discover calendars to choose a target.")}

      _ ->
        {:noreply,
         assign(socket,
           icloud_form: to_form(%{"apple_id" => params["apple_id"]}, as: :icloud),
           error: "Unable to verify iCloud Calendar credentials."
         )}
    end
  end

  def handle_event("review-migration", %{"id" => id}, socket) do
    if Enum.any?(
         socket.assigns.sync_targets,
         &(&1.binding.id == id && &1.binding.legacy_collection_id)
       ) do
      case CalendarMigration.review(id) do
        {:ok, preview} ->
          {:noreply, assign(socket, migration_preview: preview)}

        _ ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Unable to verify the retained connection and compare its baseline. Reconnect the same identity before retrying."
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("activate-migration", _, socket) do
    preview = socket.assigns.migration_preview

    case preview && CalendarMigration.activate(preview.binding_id, preview.token) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(migration_preview: nil)
         |> refresh()
         |> put_flash(
           :info,
           "Reviewed synchronization activated. Unknown prior requests reconcile before new writes."
         )}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The migration preview changed. Review it again before activating."
         )}
    end
  end

  def handle_event("preview-disconnect", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.connections, &(&1.id == id)) do
      {:noreply, assign(socket, disconnect_preview: CalendarConnections.disconnect_preview(id))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("disconnect-connection", _, socket) do
    preview = socket.assigns.disconnect_preview

    case preview && CalendarConnections.disconnect(preview.connection_id, preview.token) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(disconnect_preview: nil)
         |> refresh()
         |> put_flash(
           :info,
           "Calendar authorization removed. Local data, other providers and Contacts are retained."
         )}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Affected bindings changed. Preview the disconnection again.")}
    end
  end

  defp refresh(socket) do
    calendars = Calendars.list_calendars()
    ids = Enum.map(calendars, & &1.id)
    visible = Enum.filter(socket.assigns.visible_ids || ids, &(&1 in ids))
    days = Display.month_days(socket.assigns.selected_date)

    {occurrences, error} =
      case Calendars.list_occurrences(visible,
             from: hd(days),
             until: Date.add(List.last(days), 1),
             timezone: socket.assigns.viewing_timezone
           ) do
        {:ok, occurrences} -> {occurrences, nil}
        {:error, errors} -> {[], "Some events cannot be expanded: " <> inspect(errors)}
      end

    calendar =
      if socket.assigns.calendar, do: Enum.find(calendars, &(&1.id == socket.assigns.calendar.id))

    event = if socket.assigns.event, do: Calendars.get_event(socket.assigns.event.id)

    assign(socket,
      calendars: calendars,
      visible_ids: visible,
      days: days,
      occurrences: occurrences,
      agenda: Display.agenda(occurrences, socket.assigns.selected_date),
      calendar: calendar,
      event: event,
      sync_targets: if(calendar, do: Calendars.sync_summary(calendar.id), else: []),
      enrollment_preview:
        socket.assigns.enrollment_preview ||
          if(calendar,
            do: Enum.find(Calendars.list_bindings(calendar.id), &(&1.state == "preview"))
          ),
      event_bindings:
        if(event,
          do:
            Repo.all(from e in CalendarEventBinding, where: e.event_id == ^event.id)
            |> Repo.preload([:resource, binding: :connection]),
          else: []
        ),
      connections: CalendarConnections.list(),
      error: error || socket.assigns.error
    )
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
          <.dm_mdi name="calendar-outline" class="w-6 h-6" /><h1>Calendar</h1>
        </div>
        <.dm_btn
          :if={@writer_id}
          id="new-event"
          patch={calendar_path(@writer_id, assigns, "/events/new")}
          variant="primary"
          class="calendar-create"
        >
          Create event
        </.dm_btn>
        <div class="calendar-source-heading">
          <h2>Visible calendars</h2><.link
            id="new-calendar"
            patch={calendar_path(nil, assigns, "/new")}
            aria-label="Add calendar"
          >Add</.link>
        </div>
        <div class="calendar-sources" aria-label="Calendar visibility">
          <div :for={calendar <- @calendars} class="calendar-source">
            <input
              id={"visible-#{calendar.id}"}
              type="checkbox"
              checked={calendar.id in @visible_ids}
              phx-click="toggle-calendar"
              phx-value-id={calendar.id}
              aria-label={"Show #{calendar.name}"}
            />
            <.link
              id={"calendar-#{calendar.id}"}
              patch={calendar_path(calendar.id, assigns)}
              aria-current={@calendar && @calendar.id == calendar.id && "page"}
            >{calendar.name}</.link>
          </div>
        </div>
        <.form
          :if={@calendars != []}
          for={to_form(%{"calendar_id" => @writer_id}, as: :writer)}
          id="default-calendar-form"
          phx-change="set-writer"
        >
          <label for="default-calendar">Save new events to</label>
          <select id="default-calendar" name="writer[calendar_id]" class="select w-full">
            <option
              :for={calendar <- @calendars}
              value={calendar.id}
              selected={calendar.id == @writer_id}
            >
              {calendar.name}
            </option>
          </select>
        </.form>
        <div class="calendar-sidebar-footer">
          <p>Local calendars. Optional Google and iCloud synchronization.</p><a href="#calendar-connections">Manage calendar connections</a>
        </div>
      </aside>
      <div class="calendar-main">
        <header class="calendar-toolbar">
          <%!-- # TODO(upstream): duskmoon-dev/duskmoon-elements#86 --%>
          <%!-- # WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#86 — slotted text names the internal button. --%>
          <.dm_btn
            id="calendar-navigation-toggle"
            class="calendar-mobile-toggle"
            variant="ghost"
            phx-click="toggle-navigation"
            aria-expanded={to_string(@navigation_open)}
          >
            <.dm_mdi name="menu" class="w-5 h-5" /><span class="sr-only">{if @navigation_open,
              do: "Close calendar navigation",
              else: "Open calendar navigation"}</span>
          </.dm_btn>
          <.dm_btn
            id="calendar-today"
            variant="outline"
            patch={calendar_path(@calendar && @calendar.id, Map.put(assigns, :selected_date, @today))}
          >
            Today
          </.dm_btn>
          <div class="calendar-month-heading">
            <.link
              id="calendar-previous-month"
              class="calendar-icon-link"
              patch={
                calendar_path(
                  @calendar && @calendar.id,
                  Map.put(assigns, :selected_date, Display.shift_month(@selected_date, -1))
                )
              }
              aria-label="Previous month"
            >‹</.link>
            <h2>{Elixir.Calendar.strftime(@selected_date, "%B %Y")}</h2>
            <.link
              id="calendar-next-month"
              class="calendar-icon-link"
              patch={
                calendar_path(
                  @calendar && @calendar.id,
                  Map.put(assigns, :selected_date, Display.shift_month(@selected_date, 1))
                )
              }
              aria-label="Next month"
            >›</.link>
          </div>
          <nav class="calendar-view-switch" aria-label="Calendar view">
            <.link
              aria-current={@display_view == "month" && "page"}
              patch={
                calendar_path(@calendar && @calendar.id, Map.put(assigns, :display_view, "month"))
              }
            >Month</.link><.link
              aria-current={@display_view == "agenda" && "page"}
              patch={
                calendar_path(@calendar && @calendar.id, Map.put(assigns, :display_view, "agenda"))
              }
            >Agenda</.link>
          </nav>
          <.form
            for={to_form(%{"timezone" => @viewing_timezone}, as: :viewing)}
            id="viewing-timezone-form"
            phx-submit="set-timezone"
            class="calendar-timezone-form"
          >
            <label for="viewing-timezone">Viewing time zone</label><input
              id="viewing-timezone"
              name="viewing[timezone]"
              value={@viewing_timezone}
              class="input"
            /><.dm_btn type="submit" variant="ghost">Apply</.dm_btn>
          </.form>
        </header>
        <p :if={@error} id="calendar-error" role="alert" class="p-4 text-error">{@error}</p>
        <div :if={@calendars == []} id="calendars-empty" class="p-8">
          <h2>Your local calendar</h2><p>
            Create a calendar to start. An email account or cloud connection is optional.
          </p>
        </div>
        <p id="calendar-recurrence-help" class="px-4 text-sm text-on-surface-variant">
          Repeating events and exceptions appear in your viewing time zone. All-day events keep their dates.
        </p>
        <div id="calendar-events">
          <div
            :if={@display_view == "month"}
            class="calendar-month-grid"
            role="grid"
            aria-label="Month events"
          >
            <span
              :for={weekday <- ~w(Mon Tue Wed Thu Fri Sat Sun)}
              class="calendar-weekday"
              role="columnheader"
            >{weekday}</span>
            <div
              :for={day <- @days}
              class={["calendar-day", day.month != @selected_date.month && "outside-month"]}
              role="gridcell"
              aria-label={Date.to_iso8601(day)}
            >
              <time datetime={Date.to_iso8601(day)} class="calendar-day-number">{day.day}</time>
              <.link
                :for={occurrence <- Enum.filter(@occurrences, &Display.on_day?(&1, day))}
                patch={event_path(occurrence.event, assigns, occurrence.recurrence_id)}
                class="calendar-event"
                data-event-id={occurrence.event_id}
              >
                <span>{occurrence.clock}</span><strong>{occurrence.event.summary || "Untitled event"}</strong><small>{occurrence.event.calendar.name}</small>
              </.link>
            </div>
          </div>
          <div
            id="calendar-agenda"
            class={["calendar-agenda", @display_view == "month" && "mobile-agenda"]}
          >
            <section :for={{day, occurrences} <- @agenda}>
              <h3>{Elixir.Calendar.strftime(day, "%A, %B %-d")}</h3><.link
                :for={occurrence <- occurrences}
                patch={event_path(occurrence.event, assigns, occurrence.recurrence_id)}
                class="calendar-agenda-event"
                data-event-id={occurrence.event_id}
              ><time class="calendar-agenda-time">{occurrence.clock}</time><span class="calendar-agenda-summary"><strong>{occurrence.event.summary ||
                "Untitled event"}</strong><small>{occurrence.event.calendar.name}</small></span></.link>
            </section>
            <p :if={@agenda == []} class="p-6">No events in the selected month.</p>
          </div>
        </div>
        <section
          :if={@calendar}
          id="calendar-sync-targets"
          class="p-4 space-y-3 border-t border-outline-variant"
        >
          <header class="flex gap-3 items-center">
            <h2>{@calendar.name}: synchronization targets</h2><.link
              id="edit-calendar"
              patch={calendar_path(@calendar.id, assigns, "/edit")}
            >Edit local calendar</.link>
          </header>
          <p :if={@sync_targets == []}>Local only. Add a target when you want synchronization.</p>
          <article
            :for={target <- @sync_targets}
            id={"binding-#{target.binding.id}"}
            class="p-3 rounded bg-surface-container"
          >
            <strong>{String.capitalize(target.binding.connection.provider)} · {target.binding.name ||
              target.binding.remote_calendar_id}</strong>
            <p>
              {target.binding.state} · {target.pending} pending · {target.conflicts} conflicts · {target.limited} limited
            </p>
            <p :if={target.binding.direction == "inbound"}>
              Read-only source. Incoming events can be copied to an editable local calendar.
            </p>
            <p :if={target.binding.last_error} class="text-error">{target.binding.last_error}</p>
            <.dm_btn
              :if={
                target.binding.legacy_collection_id &&
                  target.binding.enrollment_manifest["identity_verification_required"] == true
              }
              variant="outline"
              phx-click="review-migration"
              phx-value-id={target.binding.id}
            >
              Review existing synchronization
            </.dm_btn>
            <.dm_btn
              :if={target.binding.state == "active"}
              variant="ghost"
              phx-click="binding-action"
              phx-value-id={target.binding.id}
              phx-value-action="pause"
            >
              Pause this target
            </.dm_btn>
            <.dm_btn
              :if={target.binding.state in ["paused", "unavailable"]}
              variant="ghost"
              phx-click="binding-action"
              phx-value-id={target.binding.id}
              phx-value-action="resume"
            >
              Resume and reconcile
            </.dm_btn>
            <.dm_btn
              :if={target.binding.state == "detached"}
              variant="outline"
              phx-click="binding-action"
              phx-value-id={target.binding.id}
              phx-value-action="reenroll"
            >
              Preview explicit re-enrollment
            </.dm_btn>
            <.dm_btn
              :if={target.binding.state != "detached"}
              variant="ghost"
              phx-click="binding-action"
              phx-value-id={target.binding.id}
              phx-value-action="detach"
              data-confirm="Detach this target and retain local and cloud events? Other targets continue synchronizing."
            >
              Detach and retain data
            </.dm_btn>
          </article>
        </section>
        <section
          :if={@migration_preview}
          id="calendar-migration-preview"
          class="p-4 bg-surface-container"
        >
          <h2>Review existing synchronization</h2><p>
            Identity verified. Compared {length(@migration_preview.report["resources"] || [])} remote resources against retained local revisions and baselines. No provider writes have been sent by this review.
          </p>
          <ul>
            <li :for={resource <- @migration_preview.report["resources"] || []}>
              {resource["id"]}: {Enum.map_join(resource["components"] || [], ", ", & &1["status"])}
            </li>
          </ul>
          <.dm_btn variant="outline" phx-click="activate-migration">
            Confirm reviewed activation
          </.dm_btn>
        </section>
        <section id="calendar-connections" class="p-4 border-t border-outline-variant space-y-3">
          <h2>Calendar connections</h2><p>
            Connect independently of your email accounts. Adding a target always starts with an initial-sync preview.
          </p>
          <a href="/calendar-connections/google/start" class="link">Connect Google Calendar</a>
          <details>
            <summary>Connect iCloud Calendar</summary><.form
              for={@icloud_form}
              id="icloud-calendar-form"
              phx-submit="connect-icloud"
              class="space-y-2"
            >
              <label for="icloud-apple-id">Apple Account</label><input
                id="icloud-apple-id"
                name="icloud[apple_id]"
                type="email"
                value={@icloud_form[:apple_id].value}
                required
                class="input"
                autocomplete="username"
              />
              <label for="icloud-app-password">App-specific password</label><input
                id="icloud-app-password"
                name="icloud[app_password]"
                type="password"
                required
                class="input"
                autocomplete="new-password"
              />
              <.dm_btn type="submit" variant="outline">Verify and connect iCloud Calendar</.dm_btn>
            </.form>
          </details>
          <.form
            :if={@calendar && @connections != []}
            for={to_form(%{}, as: :connection)}
            id="calendar-discovery-form"
            phx-submit="discover-calendars"
          >
            <label for="calendar-connection">Connection</label><select
              id="calendar-connection"
              name="connection[id]"
              class="select"
            ><option :for={connection <- @connections} value={connection.id}>
              {String.capitalize(connection.provider)} · {connection.display_name ||
                connection.remote_identity || connection.id} · {connection.status}
            </option></select><.dm_btn type="submit" variant="outline">Discover calendars</.dm_btn>
          </.form>
          <div :for={connection <- @connections} class="flex flex-wrap gap-3 items-center">
            <span>{String.capitalize(connection.provider)} · {connection.display_name ||
              connection.remote_identity} · {connection.status}</span><.dm_btn
              variant="ghost"
              phx-click="preview-disconnect"
              phx-value-id={connection.id}
            >
              Preview authorization removal
            </.dm_btn>
          </div>
          <section :if={@disconnect_preview} id="calendar-disconnect-preview">
            <h3>Remove Calendar authorization</h3><p>
              {length(@disconnect_preview.binding_ids)} calendar bindings will pause. Local events and other providers are retained. Contacts credentials are retained. In-flight outcomes remain recorded for reconciliation.
            </p><.dm_btn variant="error" phx-click="disconnect-connection">
              Confirm removing Calendar authorization
            </.dm_btn>
          </section>
          <div :for={remote <- @discovered} class="flex flex-wrap gap-3 items-center">
            <span>{remote.name}</span><.dm_btn
              variant="ghost"
              phx-click="preview-enrollment"
              phx-value-remote_id={remote.id}
            >
              Preview for {@calendar.name}
            </.dm_btn>
          </div>
        </section>
        <section
          :if={@enrollment_preview}
          id="calendar-enrollment-preview"
          class="p-4 bg-surface-container space-y-3"
        >
          <h2>Confirm initial synchronization</h2><p>
            {@enrollment_preview.enrollment_manifest["impact"]}
          </p><p>
            Similar titles, times or UIDs are kept as separate events unless you explicitly claim an identity below.
          </p>
          <.form
            for={to_form(%{}, as: :enrollment)}
            id="calendar-enrollment-form"
            phx-submit="confirm-enrollment"
          >
            <fieldset>
              <legend>Upload existing local events</legend><label
                :for={{id, revision} <- @enrollment_preview.enrollment_manifest["local_revisions"]}
                class="block"
              ><input type="checkbox" name="enrollment[uploads][]" value={id} /> {local_event_label(
                id
              )} · revision {revision}</label>
            </fieldset>
            <fieldset>
              <legend>Import remote resources and propagate to other targets</legend><label
                :for={resource <- @enrollment_preview.enrollment_manifest["resources"]}
                class="block"
              ><input type="checkbox" name="enrollment[imports][]" value={resource["id"]} /> {remote_label(
                resource
              )}</label>
            </fieldset>
            <fieldset>
              <legend>Explicit identity claims (optional)</legend>
              <div :for={resource <- @enrollment_preview.enrollment_manifest["resources"]}>
                <label :for={component <- resource["components"] || []} class="block">
                  {component["projection"]["summary"] || "Untitled remote event"} · {component[
                    "projection"
                  ]["starts_at"]}
                  <select
                    name={"enrollment[claims][#{claim_option(resource["id"], component["key"])}]"}
                    class="select"
                  >
                    <option value="">Keep an independent identity</option>
                    <option
                      :for={
                        {id, _revision} <- @enrollment_preview.enrollment_manifest["local_revisions"]
                      }
                      value={id}
                    >
                      Link to {local_event_label(id)}
                    </option>
                  </select>
                </label>
              </div>
            </fieldset>
            <p class="text-sm">
              Claims connect identities; differing versions remain a conflict for review.
            </p><.dm_btn type="submit" variant="primary">Confirm selected synchronization</.dm_btn>
          </.form>
        </section>
      </div>
      <aside
        :if={@calendar_form || @event_form || @event}
        class="calendar-drawer"
        aria-label="Calendar details"
      >
        <.link patch={calendar_path(@calendar && @calendar.id, assigns)} aria-label="Close details">Close</.link>
        <.form
          :if={@calendar_form}
          for={@calendar_form}
          id="calendar-form"
          phx-change="validate-calendar"
          phx-submit="save-calendar"
          class="space-y-3 p-4"
        >
          <h2>
            {if @live_action == :edit_calendar, do: "Edit local calendar", else: "New local calendar"}
          </h2><label for="calendar-name">Name</label><input
            id="calendar-name"
            name="calendar[name]"
            value={@calendar_form[:name].value}
            required
            class="input w-full"
          />
          <p>
            Synchronization targets are managed separately. Saving a calendar never merges local identities.
          </p><.dm_btn type="submit" variant="primary">Save calendar</.dm_btn>
          <.dm_btn
            :if={@live_action == :edit_calendar}
            id="delete-calendar"
            variant="error"
            phx-click="delete-calendar"
            data-confirm="Delete this local calendar and archive its bindings? Cloud calendars and cloud events will be retained."
          >
            Delete local calendar
          </.dm_btn>
        </.form>
        <.form
          :if={@event_form}
          for={@event_form}
          id="event-form"
          phx-change="validate-event"
          phx-submit="save-event"
          class="space-y-3 p-4"
        >
          <h2>{if @live_action == :edit_event, do: "Edit event", else: "New event"}</h2><p>
            Saved in {@calendar.name}. {upload_notice(@calendar)}
          </p>
          <label for="event-summary">Title</label><input
            id="event-summary"
            name="event[summary]"
            value={@event_form[:summary].value}
            class="input w-full"
          />
          <label for="event-all-day"><input type="hidden" name="event[all_day]" value="false" /><input
            id="event-all-day"
            type="checkbox"
            name="event[all_day]"
            value="true"
            checked={truthy?(@event_form[:all_day].value)}
          /> All day</label>
          <label for={
            if truthy?(@event_form[:all_day].value), do: "event-start-date", else: "event-start-time"
          }>Start</label><input
            id={
              if truthy?(@event_form[:all_day].value),
                do: "event-start-date",
                else: "event-start-time"
            }
            name="event[starts_at]"
            type={if truthy?(@event_form[:all_day].value), do: "date", else: "datetime-local"}
            value={@event_form[:starts_at].value}
            required
            class="input w-full"
          />
          <label for={
            if truthy?(@event_form[:all_day].value), do: "event-end-date", else: "event-end-time"
          }>End (exclusive for all-day events)</label><input
            id={if truthy?(@event_form[:all_day].value), do: "event-end-date", else: "event-end-time"}
            name="event[ends_at]"
            type={if truthy?(@event_form[:all_day].value), do: "date", else: "datetime-local"}
            value={@event_form[:ends_at].value}
            class="input w-full"
          />
          <label for="event-timezone">Source time zone (blank means floating; UTC means UTC)</label><input
            id="event-timezone"
            name="event[timezone]"
            value={@event_form[:timezone].value}
            class="input w-full"
          />
          <label for="event-location">Location</label><input
            id="event-location"
            name="event[location]"
            value={@event_form[:location].value}
            class="input w-full"
          />
          <label for="event-description">Description</label><textarea
            id="event-description"
            name="event[description]"
            class="textarea w-full"
          >{@event_form[:description].value}</textarea>
          <label for="event-rules">Recurrence rules (one RRULE per line)</label><textarea
            id="event-rules"
            name="event[recurrence_rules]"
            class="textarea w-full"
          >{@event_form[:recurrence_rules].value}</textarea>
          <label for="event-rdates">Additional dates (RDATE lines or compact dates)</label><textarea
            id="event-rdates"
            name="event[recurrence_dates]"
            class="textarea w-full"
          >{@event_form[:recurrence_dates].value}</textarea>
          <label for="event-exdates">Excluded dates (EXDATE lines or compact dates)</label><textarea
            id="event-exdates"
            name="event[excluded_dates]"
            class="textarea w-full"
          >{@event_form[:excluded_dates].value}</textarea>
          <p :if={@occurrence_slot != ""}>
            This edit affects occurrence {@occurrence_slot}; its original identity is retained.
          </p><.dm_btn type="submit" variant="primary">Save event</.dm_btn>
        </.form>
        <section :if={@event && !@event_form} id="calendar-event-detail" class="p-4 space-y-3">
          <h2>{@event.summary || "Untitled event"}</h2><p>
            {if @event.read_only, do: "Read-only source", else: "Local event"}
          </p><p>{event_period(@event, @viewing_timezone)}</p><p>{@event.location}</p><p class="whitespace-pre-wrap">
            {@event.description}
          </p>
          <p :if={Display.recurring?(@event)}>Series: {Enum.join(@event.recurrence_rules, "; ")}</p><p :if={
            @occurrence_slot != ""
          }>
            Original recurrence slot: {@occurrence_slot}
          </p><p :if={@event.excluded_dates != []}>
            Excluded: {Enum.join(@event.excluded_dates, ", ")}
          </p>
          <div id="event-sync-status">
            <p :if={@event_bindings == []}>Local only</p><p :for={binding <- @event_bindings}>
              Target {String.capitalize(binding.binding.connection.provider)}: acknowledged revision {binding.acknowledged_revision} / desired {binding.desired_revision} · {binding.state} · {binding.resource.status}
              <span :if={binding.resource.status == "uncertain"}>Confirming an unknown remote outcome before retrying.</span>
              <span :if={binding.resource.last_error} class="text-error">{binding.resource.last_error}</span>
              <span :if={binding.last_error} class="text-error">{binding.last_error}</span>
            </p>
          </div>
          <.link
            :if={!@event.read_only}
            id="edit-event"
            patch={event_path(@event, assigns, @occurrence_slot, "/edit")}
          >Edit {if @occurrence_slot != "", do: "this occurrence", else: "event / series"}</.link>
          <.dm_btn
            :if={!@event.read_only && (!Display.recurring?(@event) || @occurrence_slot != "")}
            id="delete-event-occurrence"
            variant="error"
            phx-click="delete-event"
            phx-value-scope="occurrence"
            data-confirm="Delete this occurrence and propagate its deletion to enrolled targets?"
          >
            {if Display.recurring?(@event), do: "Delete this occurrence", else: "Delete event"}
          </.dm_btn>
          <.dm_btn
            :if={!@event.read_only && Display.recurring?(@event)}
            id="delete-event-series"
            variant="error"
            phx-click="delete-event"
            phx-value-scope="series"
            data-confirm="Delete the entire series from this local calendar and its enrolled targets?"
          >
            Delete whole series
          </.dm_btn>
          <.form
            for={to_form(%{}, as: :copy)}
            id="event-copy-form"
            phx-submit="copy-event"
            class="space-y-2"
          >
            <h3>Create an independent copy</h3><label for="copy-calendar">Destination</label><select
              id="copy-calendar"
              name="copy[calendar_id]"
              class="select w-full"
            ><option :for={calendar <- @calendars} value={calendar.id}>
              {calendar.name} · {upload_notice(calendar)}
            </option></select>
            <label for="copy-scope">Copy scope</label><select
              id="copy-scope"
              name="copy[scope]"
              class="select"
            ><option :if={!Display.recurring?(@event)} value="event">Event</option><option
              :if={Display.recurring?(@event)}
              value="series"
            >
              Whole series and exceptions
            </option><option
              :if={Display.recurring?(@event) && @occurrence_slot != ""}
              value="occurrence"
            >
              This occurrence only
            </option></select>
            <label class="block"><input type="checkbox" name="copy[confirm_upload]" value="true" />
            I confirm uploading the copy if the destination has synchronization targets.</label><.dm_btn
              type="submit"
              variant="outline"
            >
              Create copy
            </.dm_btn>
          </.form>
          <article
            :for={binding <- Enum.filter(@event_bindings, & &1.conflict)}
            class="p-3 bg-surface-container"
          >
            <p>
              Conflict on target {binding.binding_id}. Other targets can continue with the accepted local version.
            </p><.dm_btn variant="outline" phx-click="preview-conflict" phx-value-id={binding.id}>
              Preview conflict and affected targets
            </.dm_btn>
          </article>
          <section :if={@conflict_preview} id="calendar-conflict-preview">
            <h3>Choose the accepted version</h3><p>
              This choice creates a new local revision and propagates to {length(
                @conflict_preview.targets
              )} enrolled targets. Concurrent changes invalidate this preview.
            </p><h4>Local</h4><pre class="whitespace-pre-wrap">{Jason.encode!(@conflict_preview.local, pretty: true)}</pre><h4>
              Remote candidate
            </h4><pre class="whitespace-pre-wrap">{Jason.encode!(@conflict_preview.remote, pretty: true)}</pre><h4>
              Common baseline
            </h4><pre class="whitespace-pre-wrap">{Jason.encode!(@conflict_preview.base, pretty: true)}</pre><.dm_btn
              variant="outline"
              phx-click="resolve-conflict"
              phx-value-choice="local"
            >
              Keep local and synchronize
            </.dm_btn><.dm_btn
              variant="outline"
              phx-click="resolve-conflict"
              phx-value-choice="remote"
            >
              Accept remote and propagate
            </.dm_btn>
          </section>
        </section>
      </aside>
    </section>
    """
  end

  defp event_form(socket, event) do
    revision = edit_revision(socket, event)
    event = occurrence_values(socket, event)

    values =
      Map.new(@event_fields, fn field ->
        value = Map.get(event, String.to_existing_atom(field))
        value = if is_list(value), do: Enum.join(value, "\n"), else: value
        {field, value}
      end)

    values =
      values
      |> Map.put("starts_at", input_time(event.starts_at))
      |> Map.put("ends_at", input_time(event.ends_at))
      |> Map.put(
        "timezone",
        event.timezone ||
          if(is_binary(event.starts_at) && String.ends_with?(event.starts_at, "Z"),
            do: "UTC",
            else: ""
          )
      )

    assign(socket, event_form: to_form(values, as: :event), editing_revision: revision)
  end

  defp edit_revision(_socket, event), do: event.local_revision

  defp occurrence_values(socket, event) do
    slot = socket.assigns.occurrence_slot

    if event.id && slot != "" && event.recurrence_id in [nil, ""] && Display.recurring?(event) do
      zone = event.timezone || "Etc/UTC"

      with {:ok, period} <- CalendarTime.period(event, zone),
           {:ok, start} <- CalendarTime.parse(slot, event.timezone, zone) do
        finish =
          case start do
            %Date{} ->
              Date.add(start, Date.diff(period.ends_at, period.starts_at))

            %DateTime{} ->
              DateTime.add(
                start,
                DateTime.diff(period.ends_at, period.starts_at, :microsecond),
                :microsecond
              )
          end

        compact = fn time ->
          value = CalendarTime.compact(time)

          if String.ends_with?(event.starts_at, "Z"),
            do: value,
            else: String.trim_trailing(value, "Z")
        end

        %{
          event
          | starts_at: compact.(start),
            ends_at: compact.(finish),
            recurrence_rules: [],
            recurrence_dates: [],
            excluded_dates: []
        }
      else
        _ -> event
      end
    else
      event
    end
  end

  defp normalize_event(attrs) do
    all_day = truthy?(attrs["all_day"])

    attrs =
      Map.new(attrs, fn {key, value} ->
        {key,
         if(value == "" && key in ["ends_at", "timezone", "description", "location"],
           do: nil,
           else: value
         )}
      end)

    attrs = if all_day, do: Map.put(attrs, "timezone", nil), else: attrs

    attrs =
      Enum.reduce(["starts_at", "ends_at"], attrs, fn key, result ->
        Map.update(result, key, nil, &stored_time(&1, all_day, attrs["timezone"]))
      end)

    attrs =
      Enum.reduce(["recurrence_rules", "recurrence_dates", "excluded_dates"], attrs, fn key,
                                                                                        result ->
        Map.update(result, key, [], fn value ->
          if is_list(value), do: value, else: String.split(value || "", ~r/\r?\n/, trim: true)
        end)
      end)

    Map.put(attrs, "all_day", all_day)
  end

  defp stored_time(nil, _, _), do: nil

  defp stored_time(value, all_day, timezone) do
    compact = String.replace(value, ["-", ":"], "")
    compact = if byte_size(compact) == 13, do: compact <> "00", else: compact

    cond do
      all_day -> String.slice(compact, 0, 8)
      timezone in ["UTC", "Etc/UTC"] && not String.ends_with?(compact, "Z") -> compact <> "Z"
      timezone not in ["UTC", "Etc/UTC"] -> String.trim_trailing(compact, "Z")
      true -> compact
    end
  end

  defp input_mode(value, true) when is_binary(value), do: String.slice(value, 0, 10)

  defp input_mode(value, false) when is_binary(value) and byte_size(value) == 10,
    do: value <> "T09:00:00"

  defp input_mode(value, _), do: value
  defp input_time(nil), do: ""

  defp input_time(
         <<y::binary-size(4), m::binary-size(2), d::binary-size(2), "T", h::binary-size(2),
           minute::binary-size(2), sec::binary-size(2), _::binary>>
       ),
       do: "#{y}-#{m}-#{d}T#{h}:#{minute}:#{sec}"

  defp input_time(<<y::binary-size(4), m::binary-size(2), d::binary-size(2)>>),
    do: "#{y}-#{m}-#{d}"

  defp input_time(value), do: value

  defp viewed_event_date(event, timezone) do
    case CalendarTime.period(event, timezone) do
      {:ok, period} -> Display.date(period.starts_at)
      _ -> nil
    end
  end

  defp parse_date(value) when is_binary(value),
    do:
      (case Date.from_iso8601(value) do
         {:ok, date} -> date
         _ -> nil
       end)

  defp parse_date(_), do: nil

  defp valid_timezone?(zone),
    do: match?({:ok, _}, CalendarTime.parse("20261019T120000Z", nil, zone))

  defp truthy?(value), do: value in [true, "true", "on"]

  defp calendar_path(id, assigns, suffix \\ "") do
    base = if id, do: "/calendars/" <> id, else: "/calendars"

    base <>
      suffix <>
      "?" <>
      URI.encode_query(%{
        "date" => Date.to_iso8601(assigns.selected_date),
        "view" => assigns.display_view,
        "timezone" => assigns.viewing_timezone
      })
  end

  defp event_path(event, assigns, slot \\ "", suffix \\ "") do
    calendar_path(event.calendar_id, assigns, "/events/" <> event.id <> suffix) <>
      if(slot == "", do: "", else: "&" <> URI.encode_query(%{"occurrence" => slot}))
  end

  defp upload_notice(calendar) do
    if Enum.any?(
         calendar.bindings,
         &(&1.state in ["active", "paused"] && &1.direction == "bidirectional")
       ),
       do: "Uploads to confirmed synchronization targets",
       else: "Local only"
  end

  defp event_period(event, zone) do
    case CalendarTime.period(event, zone) do
      {:ok, period} ->
        "#{period.starts_at} — #{period.ends_at} (#{if period.all_day, do: "all day", else: zone})"

      _ ->
        "Invalid event time"
    end
  end

  defp local_event_label(id),
    do:
      (case Calendars.get_event(id) do
         nil -> id
         event -> (event.summary || "Untitled event") <> " · " <> id
       end)

  defp remote_label(resource),
    do:
      Enum.map_join(resource["components"] || [], ", ", fn c ->
        c["projection"]["summary"] || c["key"]
      end) <> " · " <> resource["id"]

  defp claim_option(resource_id, component_key),
    do: Base.url_encode64(resource_id <> "/" <> component_key, padding: false)

  defp parse_claims(value) when is_map(value) do
    Enum.reduce_while(value, %{}, fn {encoded, local}, result ->
      if local == "" do
        {:cont, result}
      else
        case Base.url_decode64(encoded, padding: false) do
          {:ok, identity} -> {:cont, Map.put(result, identity, local)}
          _ -> {:halt, :invalid}
        end
      end
    end)
  end

  defp parse_claims(value) do
    Enum.reduce_while(String.split(value, ~r/\r?\n/, trim: true), %{}, fn line, claims ->
      case String.split(line, "=", parts: 2) do
        [identity, local] -> {:cont, Map.put(claims, String.trim(identity), String.trim(local))}
        _ -> {:halt, :invalid}
      end
    end)
  end
end

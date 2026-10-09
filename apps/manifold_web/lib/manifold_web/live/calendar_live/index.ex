defmodule ManifoldWeb.CalendarLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.Calendars

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Calendars",
       offset: 0,
       calendars: [],
       calendar: nil,
       events: [],
       event: nil
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    calendars = Calendars.list_calendars()
    calendar = Enum.find(calendars, &(&1.id == params["calendar_id"]))
    calendar = if params["calendar_id"], do: calendar, else: List.first(calendars)
    event = if params["id"], do: Calendars.get_event(params["id"])
    event = if event && calendar && event.collection_id == calendar.id, do: event

    offset =
      if socket.assigns.calendar && calendar && socket.assigns.calendar.id == calendar.id,
        do: socket.assigns.offset,
        else: 0

    socket =
      assign(socket,
        offset: offset,
        calendars: calendars,
        calendar: calendar,
        events:
          if(calendar,
            do: Calendars.list_events(calendar.id, limit: 50, offset: offset),
            else: []
          ),
        event: event
      )

    if (params["calendar_id"] && is_nil(calendar)) || (params["id"] && is_nil(event)) do
      {:noreply,
       socket
       |> put_flash(:error, "Calendar or event not found.")
       |> push_patch(to: ~p"/calendars")}
    else
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
       events: Calendars.list_events(socket.assigns.calendar.id, limit: 50, offset: offset)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="calendars-page" class="space-y-6">
      <div class="settings-heading">
        <div>
          <h1>Calendars</h1><p class="settings-intro">
            Read-only iCloud calendars and stored event records.
          </p>
        </div>
        <.dm_btn navigate={~p"/settings/icloud"} variant="outline">Manage iCloud</.dm_btn>
      </div>
      <p id="calendar-recurrence-help" class="text-on-surface-variant">
        Recurring events show their original rules and exceptions. This view lists stored records; it does not expand recurring occurrences.
      </p>
      <p :if={@calendars == []} id="calendars-empty">
        No calendars yet. Enable calendar synchronization in iCloud Settings.
      </p>
      <nav :if={@calendars != []} aria-label="Calendar selection" class="flex flex-wrap gap-4">
        <.link
          :for={calendar <- @calendars}
          id={"calendar-#{calendar.id}"}
          patch={~p"/calendars/#{calendar.id}"}
          aria-current={@calendar && @calendar.id == calendar.id && "page"}
          class="text-primary"
        >{calendar.name} · {calendar.connection.apple_id}</.link>
      </nav>
      <div :if={@calendar} class="grid gap-6 lg:grid-cols-2">
        <section
          class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-4 space-y-4"
          aria-label="Event records"
        >
          <h2>{@calendar.name}</h2>
          <p :if={@events == []} id="calendar-events-empty">No event records in this calendar.</p>
          <ul id="calendar-events" class="space-y-4">
            <li :for={event <- @events} id={"event-#{event.id}"}>
              <.link
                patch={~p"/calendars/#{@calendar.id}/events/#{event.id}"}
                class="text-primary font-semibold"
              >{event.summary || "Untitled event"}</.link>
              <p>{event_time(event.starts_at)} <span :if={event.all_day}>· All day</span></p>
              <p :if={event.timezone} class="text-sm text-on-surface-variant">{event.timezone}</p>
              <p :if={event.recurrence_rules != []}>Recurring record</p>
              <p :if={event.recurrence_id != ""}>Recurrence exception</p>
            </li>
          </ul>
          <div class="flex gap-4 mt-4">
            <.dm_btn
              id="events-previous"
              type="button"
              variant="ghost"
              phx-click="page"
              phx-value-direction="previous"
              disabled={@offset == 0}
            >
              Previous
            </.dm_btn>
            <.dm_btn
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
          :if={@event}
          id="calendar-event-detail"
          class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-4 space-y-4"
        >
          <h2>{@event.summary || "Untitled event"}</h2>
          <p>iCloud · {@calendar.connection.apple_id} · {@calendar.name} · Read-only</p>
          <dl class="space-y-4">
            <div>
              <dt>Start</dt><dd>{event_time(@event.starts_at)}</dd>
            </div>
            <div>
              <dt>End</dt><dd>{event_time(@event.ends_at)}</dd>
            </div>
            <div>
              <dt>Time zone</dt><dd>{@event.timezone || "Floating / unspecified"}</dd>
            </div>
            <div>
              <dt>All day</dt><dd>{if @event.all_day, do: "Yes", else: "No"}</dd>
            </div>
            <div :if={@event.location}>
              <dt>Location</dt><dd>{@event.location}</dd>
            </div>
            <div :if={@event.description}>
              <dt>Description</dt><dd class="whitespace-pre-wrap">{@event.description}</dd>
            </div>
            <div :if={@event.recurrence_rules != []}>
              <dt>Recurrence rules</dt><dd :for={rule <- @event.recurrence_rules}>{rule}</dd>
            </div>
            <div :if={@event.recurrence_id != ""}>
              <dt>Recurrence exception ID</dt><dd>{@event.recurrence_id}</dd>
            </div>
            <div :if={@event.excluded_dates != []}>
              <dt>Excluded dates</dt><dd :for={date <- @event.excluded_dates}>{date}</dd>
            </div>
          </dl>
        </section>
      </div>
    </section>
    """
  end

  defp event_time(nil), do: "Not specified"

  defp event_time(<<year::binary-size(4), month::binary-size(2), day::binary-size(2)>>),
    do: "#{year}-#{month}-#{day}"

  defp event_time(
         <<year::binary-size(4), month::binary-size(2), day::binary-size(2), "T",
           hour::binary-size(2), minute::binary-size(2), second::binary-size(2), suffix::binary>>
       )
       when suffix in ["", "Z"] do
    "#{year}-#{month}-#{day} #{hour}:#{minute}:#{second}" <>
      if(suffix == "Z", do: " UTC", else: "")
  end

  defp event_time(value), do: value
end

defmodule ManifoldWeb.CalendarLiveTest do
  use ManifoldWeb.ConnCase, async: true
  alias Manifold.Calendars
  alias Manifold.Data.CalendarSyncState

  alias Manifold.Data.Schema.{
    CalendarBinding,
    CalendarConnection,
    CalendarEvent,
    CalendarEventBinding,
    CalendarSyncResource
  }

  alias Manifold.Repo

  test "empty workspace creates local calendars without account or provider settings", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/calendars")
    assert has_element?(view, "#calendars-empty", "email account or cloud connection is optional")

    assert has_element?(
             view,
             "a[href='/calendar-connections/google/start']",
             "Connect Google Calendar"
           )

    assert has_element?(view, "#icloud-calendar-form")
    refute has_element?(view, "a[href='/settings/accounts']")
    view |> element("#new-calendar") |> render_click()
    assert URI.parse(assert_patch(view)).path == "/calendars/new"
    refute has_element?(view, "input[name='calendar[account_id]']")
    refute has_element?(view, "input[name='calendar[sync_to_icloud]']")
    view |> form("#calendar-form", calendar: %{name: "Personal"}) |> render_submit()
    [calendar] = Calendars.list_calendars()
    assert URI.parse(assert_patch(view)).path == "/calendars/#{calendar.id}"
    assert has_element?(view, "#calendar-sync-targets", "Local only")
  end

  test "offline all-day CRUD uses native controls and stable local identities", %{conn: conn} do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Personal"})
    {:ok, view, _} = live(conn, "/calendars/#{calendar.id}/events/new?date=2026-10-19")
    view |> form("#event-form", event: %{all_day: "true"}) |> render_change()
    assert has_element?(view, "input[name='event[starts_at]'][type='date']")

    view
    |> form("#event-form",
      event: %{
        summary: "Birthday",
        all_day: "true",
        starts_at: "2026-10-19",
        ends_at: "2026-10-20"
      }
    )
    |> render_submit()

    [event] = Calendars.list_events(calendar.id)
    assert event.starts_at == "20261019"
    assert event.all_day
    assert has_element?(view, "#event-sync-status", "Local only")
    view |> element("#edit-event") |> render_click()
    view |> form("#event-form", event: %{summary: "Updated"}) |> render_submit()
    assert Calendars.get_event(event.id).summary == "Updated"
    render_click(view, "delete-event", %{"scope" => "occurrence"})
    assert is_nil(Calendars.get_event(event.id))
    assert Repo.get!(CalendarEvent, event.id).deleted_at
    view |> element("#edit-calendar") |> render_click()
    view |> form("#calendar-form", calendar: %{name: "Renamed"}) |> render_submit()
    assert Calendars.get_calendar(calendar.id).name == "Renamed"
    render_click(view, "delete-calendar")
    assert is_nil(Calendars.get_calendar(calendar.id))
  end

  test "visibility overlays calendars and stays independent from the default write calendar", %{
    conn: conn
  } do
    {:ok, first} = Calendars.create_calendar(%{name: "Home"})
    {:ok, second} = Calendars.create_calendar(%{name: "Work"})

    {:ok, home} =
      Calendars.create_event(first.id, %{starts_at: "20261019", summary: "Home event"})

    {:ok, work} =
      Calendars.create_event(second.id, %{starts_at: "20261019", summary: "Work event"})

    {:ok, view, _} = live(conn, "/calendars/#{first.id}?date=2026-10-19")
    assert has_element?(view, "[data-event-id='#{home.id}']")
    assert has_element?(view, "[data-event-id='#{work.id}']")
    render_click(view, "toggle-calendar", %{"id" => first.id})
    refute has_element?(view, "[data-event-id='#{home.id}']")
    assert has_element?(view, "[data-event-id='#{work.id}']")
    view |> form("#default-calendar-form", writer: %{calendar_id: second.id}) |> render_change()
    assert has_element?(view, "#new-event[href^='/calendars/#{second.id}/events/new']")
    assert has_element?(view, "#visible-#{first.id}:not([checked])")
  end

  test "UTC times cross viewing dates and old recurring masters expand into the selected month",
       %{conn: conn} do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Travel"})

    {:ok, event} =
      Calendars.create_event(calendar.id, %{
        starts_at: "20260101T233000Z",
        ends_at: "20260102T003000Z",
        summary: "Daily call",
        recurrence_rules: ["FREQ=DAILY"]
      })

    {:ok, view, _} =
      live(conn, "/calendars/#{calendar.id}?date=2026-10-20&timezone=Asia%2FShanghai")

    assert has_element?(view, "[aria-label='2026-10-20'] [data-event-id='#{event.id}']", "07:30")

    assert has_element?(
             view,
             "#calendar-agenda.mobile-agenda [data-event-id='#{event.id}']",
             "07:30"
           )

    assert has_element?(view, "#calendar-recurrence-help", "Repeating events and exceptions")
    view |> element("nav[aria-label='Calendar view'] a", "Agenda") |> render_click()

    assert has_element?(
             view,
             "#calendar-agenda:not(.mobile-agenda) [data-event-id='#{event.id}']",
             "07:30"
           )

    view |> form("#viewing-timezone-form", viewing: %{timezone: "Not/AZone"}) |> render_submit()
    assert has_element?(view, "#calendar-error", "valid IANA")
  end

  test "source floating and UTC values remain distinct when edited", %{conn: conn} do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Local"})
    {:ok, view, _} = live(conn, "/calendars/#{calendar.id}/events/new")

    view
    |> form("#event-form",
      event: %{summary: "Floating", starts_at: "2026-10-19T10:30", ends_at: "2026-10-19T11:30"}
    )
    |> render_submit()

    [event] = Calendars.list_events(calendar.id)
    assert event.starts_at == "20261019T103000"
    assert event.timezone == nil
    view |> element("#edit-event") |> render_click()
    view |> form("#event-form", event: %{timezone: "UTC"}) |> render_submit()
    assert Calendars.get_event(event.id).starts_at == "20261019T103000Z"
    view |> element("#edit-event") |> render_click()
    assert has_element?(view, "input[name='event[starts_at]'][value='2026-10-19T10:30:00']")
  end

  test "each target displays independent pending state and single-target actions preserve the other",
       %{conn: conn} do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Shared"})
    google = target(calendar, "google")
    apple = target(calendar, "icloud")

    {:ok, _event} =
      Calendars.create_event(calendar.id, %{starts_at: "20261019", summary: "Two providers"})

    {:ok, view, _} = live(conn, "/calendars/#{calendar.id}?date=2026-10-19")
    assert has_element?(view, "#binding-#{google.id}", "1 pending")
    assert has_element?(view, "#binding-#{apple.id}", "1 pending")
    render_click(view, "binding-action", %{"id" => google.id, "action" => "pause"})
    assert has_element?(view, "#binding-#{google.id}", "paused")
    assert Repo.get!(CalendarBinding, apple.id).state == "active"
    render_click(view, "binding-action", %{"id" => google.id, "action" => "detach"})
    assert has_element?(view, "#binding-#{google.id}", "detached")
    assert Calendars.get_calendar(calendar.id).id == calendar.id
    assert Repo.get!(CalendarBinding, apple.id).state == "active"
  end

  test "read-only source content is escaped and copies have independent identity", %{conn: conn} do
    {:ok, source} = Calendars.create_calendar(%{name: "Read only"})
    {:ok, target} = Calendars.create_calendar(%{name: "Copies"})

    {:ok, event} =
      Calendars.create_event(source.id, %{
        starts_at: "20261019",
        summary: "<script>unsafe</script>",
        description: "<script>alert(1)</script>"
      })

    Repo.update!(Ecto.Changeset.change(event, read_only: true))
    {:ok, view, html} = live(conn, "/calendars/#{source.id}/events/#{event.id}")
    assert has_element?(view, "#calendar-event-detail", "Read-only")
    refute has_element?(view, "#edit-event")
    refute html =~ "<script>alert(1)</script>"

    view
    |> form("#event-copy-form", copy: %{calendar_id: target.id, scope: "event"})
    |> render_submit()

    [copy] = Calendars.list_events(target.id)
    assert copy.uid != event.uid
    assert copy.description == event.description
  end

  test "copying to an enrolled target requires an explicit upload confirmation", %{conn: conn} do
    {:ok, source} = Calendars.create_calendar(%{name: "Source"})
    {:ok, destination} = Calendars.create_calendar(%{name: "Cloud copy"})
    target(destination, "google")
    {:ok, event} = Calendars.create_event(source.id, %{starts_at: "20261019", summary: "Copy me"})
    {:ok, view, _} = live(conn, "/calendars/#{source.id}/events/#{event.id}")

    view
    |> form("#event-copy-form", copy: %{calendar_id: destination.id, scope: "event"})
    |> render_submit()

    assert Calendars.list_events(destination.id) == []
    assert render(view) =~ "Confirm that this destination uploads"

    view
    |> form("#event-copy-form",
      copy: %{calendar_id: destination.id, scope: "event", confirm_upload: "true"}
    )
    |> render_submit()

    assert length(Calendars.list_events(destination.id)) == 1
  end

  test "live changes refresh occurrence data without navigation", %{conn: conn} do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Live"})
    {:ok, view, _} = live(conn, "/calendars/#{calendar.id}?date=2026-10-19")
    refute has_element?(view, "[data-event-id]")

    {:ok, event} =
      Calendars.create_event(calendar.id, %{starts_at: "20261019", summary: "Arrived from sync"})

    assert has_element?(view, "[data-event-id='#{event.id}']", "Arrived from sync")
  end

  test "conflict preview shows local, remote and common baseline before a versioned choice", %{
    conn: conn
  } do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Conflicts"})

    {:ok, event} =
      Calendars.create_event(calendar.id, %{starts_at: "20261019", summary: "Accepted local"})

    binding = target(calendar, "google")
    projection = CalendarSyncState.projection(event)

    resource =
      Repo.insert!(%CalendarSyncResource{
        binding_id: binding.id,
        remote_resource_id: "remote",
        status: "conflict",
        remote_etag: "remote-version"
      })

    eb =
      Repo.insert!(%CalendarEventBinding{
        binding_id: binding.id,
        event_id: event.id,
        resource_id: resource.id,
        remote_component_key: event.uid <> <<31>>,
        desired_revision: 1,
        base_projection: projection,
        projection_fields: Map.keys(projection),
        conflict: %{
          "remote" => Map.put(projection, "summary", "Remote candidate"),
          "fields" => Map.keys(projection)
        }
      })

    {:ok, view, _} = live(conn, "/calendars/#{calendar.id}/events/#{event.id}")
    refute has_element?(view, "#calendar-conflict-preview")
    render_click(view, "preview-conflict", %{"id" => eb.id})
    assert has_element?(view, "#calendar-conflict-preview", "Remote candidate")
    assert has_element?(view, "#calendar-conflict-preview", "Common baseline")
    assert has_element?(view, "#calendar-conflict-preview", "Concurrent changes invalidate")
    render_click(view, "resolve-conflict", %{"choice" => "remote"})
    assert Calendars.get_event(event.id).summary == "Remote candidate"
  end

  test "editing one expanded occurrence defaults to its own slot and preserves the series", %{
    conn: conn
  } do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Recurring"})

    {:ok, master} =
      Calendars.create_event(calendar.id, %{
        starts_at: "20260101T100000Z",
        ends_at: "20260101T110000Z",
        recurrence_rules: ["FREQ=DAILY"],
        summary: "Series"
      })

    slot = "20261020T100000Z"

    {:ok, view, _} =
      live(
        conn,
        "/calendars/#{calendar.id}/events/#{master.id}/edit?date=2026-10-20&occurrence=#{slot}"
      )

    assert has_element?(view, "input[name='event[starts_at]'][value='2026-10-20T10:00:00']")

    view
    |> form("#event-form",
      event: %{
        summary: "This instance",
        starts_at: "2026-10-20T12:00",
        ends_at: "2026-10-20T13:00"
      }
    )
    |> render_submit()

    exception = Enum.find(Calendars.list_events(calendar.id), &(&1.recurrence_id == slot))
    assert exception.summary == "This instance"
    assert exception.starts_at == "20261020T120000Z"
    assert Calendars.get_event(master.id).starts_at == "20260101T100000Z"
    assert Calendars.get_event(master.id).recurrence_rules == ["FREQ=DAILY"]
  end

  test "a live refresh cannot silently advance the revision of an open edit form", %{conn: conn} do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Concurrent"})

    {:ok, event} =
      Calendars.create_event(calendar.id, %{starts_at: "20261019", summary: "Before"})

    {:ok, view, _} = live(conn, "/calendars/#{calendar.id}/events/#{event.id}/edit")
    {:ok, _} = Calendars.update_event(event.id, %{summary: "Accepted elsewhere"})
    render(view)
    view |> form("#event-form", event: %{summary: "Stale form"}) |> render_submit()
    assert has_element?(view, "#calendar-error", "changed")
    assert Calendars.get_event(event.id).summary == "Accepted elsewhere"
  end

  test "authorization removal previews affected bindings and preserves other providers", %{
    conn: conn
  } do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Connected"})
    google = target(calendar, "google")
    apple = target(calendar, "icloud")

    {:ok, event} =
      Calendars.create_event(calendar.id, %{starts_at: "20261019", summary: "Retain me"})

    {:ok, view, _} = live(conn, "/calendars/#{calendar.id}")
    render_click(view, "preview-disconnect", %{"id" => google.connection_id})
    assert has_element?(view, "#calendar-disconnect-preview", "Contacts credentials are retained")
    assert Repo.get!(CalendarConnection, google.connection_id).status == "active"
    render_click(view, "disconnect-connection")
    assert Repo.get!(CalendarConnection, google.connection_id).status == "paused"
    assert Repo.get!(CalendarBinding, apple.id).state == "active"
    assert Calendars.get_event(event.id).summary == "Retain me"
  end

  defp target(calendar, provider) do
    connection =
      Repo.insert!(%CalendarConnection{
        provider: provider,
        status: "active",
        remote_identity: Ecto.UUID.generate()
      })

    Repo.insert!(%CalendarBinding{
      calendar_id: calendar.id,
      connection_id: connection.id,
      remote_calendar_id: Ecto.UUID.generate(),
      name: "Target",
      state: "active",
      capabilities: %{"write" => true},
      enrollment_manifest: %{"confirmed_at" => "2000-01-01T00:00:00Z"}
    })
  end
end

defmodule ManifoldWeb.CalendarLiveTest do
  use ManifoldWeb.ConnCase, async: true

  alias Manifold.Calendars

  alias Manifold.Data.Schema.{
    Calendar,
    CalendarEvent,
    DAVCollection,
    DAVResource,
    ICloudConnection
  }

  alias Manifold.Repo

  test "empty calendars support local creation and explain stored recurrence limits", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/calendars")
    assert has_element?(view, "#calendars-empty")
    assert has_element?(view, "#calendar-recurrence-help", "does not expand")
    assert has_element?(view, "a[href='/settings/accounts']")
    assert has_element?(view, "#new-calendar")
  end

  test "local calendar and all-day event CRUD commits offline through native date controls", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/calendars/new")
    assert has_element?(view, "input[name='calendar[sync_to_icloud]'][type='checkbox'][checked]")
    view |> form("#calendar-form", calendar: %{name: "Local calendar"}) |> render_submit()
    [calendar] = Calendars.list_calendars()
    assert_patch(view, ~p"/calendars/#{calendar.id}")
    view |> element("#new-event") |> render_click()
    view |> form("#event-form", event: %{summary: "Birthday", all_day: "true"}) |> render_change()
    assert has_element?(view, "input[name='event[starts_at]'][type='date']")

    view
    |> form("#event-form",
      event: %{
        summary: "Birthday",
        all_day: "true",
        starts_at: "2026-10-10",
        ends_at: "2026-10-11",
        description: "Local notes"
      }
    )
    |> render_submit()

    [event] = Calendars.list_events(calendar.id)
    assert event.starts_at == "20261010"
    assert event.ends_at == "20261011"
    assert event.all_day
    assert event.resource_id == nil
    assert has_element?(view, "#event-sync-status", "Local only")
    view |> element("#edit-event") |> render_click()
    view |> form("#event-form", event: %{summary: "Updated birthday"}) |> render_submit()
    assert Calendars.get_event(event.id).summary == "Updated birthday"
    render_click(view, "delete-event", %{"scope" => "component"})
    assert Calendars.get_event(event.id) == nil
    view |> element("#edit-calendar") |> render_click()
    view |> form("#calendar-form", calendar: %{name: "Renamed"}) |> render_submit()
    assert Calendars.get_calendar(calendar.id).name == "Renamed"
    render_click(view, "delete-calendar")
    assert Calendars.get_calendar(calendar.id) == nil
  end

  test "floating and UTC edits preserve their distinct stored time semantics", %{conn: conn} do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Local"})
    {:ok, view, _} = live(conn, ~p"/calendars/#{calendar.id}/events/new")

    view
    |> form("#event-form",
      event: %{summary: "Floating", starts_at: "2026-10-10T10:30", ends_at: "2026-10-10T11:30"}
    )
    |> render_submit()

    [event] = Calendars.list_events(calendar.id)
    assert event.starts_at == "20261010T103000"
    assert event.timezone == nil
    view |> element("#edit-event") |> render_click()
    view |> form("#event-form", event: %{timezone: "UTC"}) |> render_submit()
    assert Calendars.get_event(event.id).starts_at == "20261010T103000Z"
    assert Calendars.get_event(event.id).timezone == "UTC"
    view |> element("#edit-event") |> render_click()
    assert has_element?(view, "input[name='event[starts_at]'][value='2026-10-10T10:30:00']")
  end

  test "read-only event details retain all-day recurrence and escaped content and offer local copy",
       %{conn: conn} do
    {calendar, collection} = imported_calendar_fixture(false)

    event =
      event_fixture(calendar, collection, %{
        recurrence_id: "20261010",
        summary: "Planning <script>",
        starts_at: "20261010",
        ends_at: "20261011",
        timezone: "Europe/London",
        all_day: true,
        location: "Office",
        description: "Notes <script>alert(1)</script>",
        recurrence_rules: ["FREQ=WEEKLY;COUNT=4"],
        excluded_dates: ["20261017"]
      })

    {:ok, view, html} = live(conn, ~p"/calendars/#{calendar.id}/events/#{event.id}")
    assert has_element?(view, "#calendar-event-detail", "Read-only")
    assert has_element?(view, "#calendar-event-detail", "Europe/London")
    assert has_element?(view, "#calendar-event-detail", "FREQ=WEEKLY;COUNT=4")
    assert has_element?(view, "#calendar-event-detail", "Recurrence exception ID")
    assert has_element?(view, "#calendar-event-detail", "20261017")
    assert has_element?(view, "#calendar-events", "All day")
    refute html =~ "<script>alert(1)</script>"
    refute has_element?(view, "#edit-event")
    refute has_element?(view, "#event-form")
    {:ok, local} = Calendars.create_calendar(%{name: "Local copies"})
    {:ok, view, _} = live(conn, ~p"/calendars/#{calendar.id}/events/#{event.id}")
    view |> form("#event-copy-form", copy: %{calendar_id: local.id}) |> render_submit()
    [copy] = Calendars.list_events(local.id)
    assert copy.uid != event.uid
    assert copy.resource_id == nil
    assert copy.description == event.description
  end

  test "component and whole-series deletion keep explicit scope and stage complete resource operations",
       %{conn: conn} do
    {calendar, collection} = imported_calendar_fixture(true)

    resource =
      Repo.insert!(%DAVResource{
        kind: "calendars",
        account_id: calendar.account_id,
        connection_id: collection.connection_id,
        collection_id: collection.id,
        href: "https://caldav.icloud.com/calendar/meeting.ics",
        uid: "meeting",
        base_raw: "complete original ICS",
        etag: "\"base\"",
        status: "synced"
      })

    master =
      event_fixture(calendar, collection, %{
        resource_id: resource.id,
        recurrence_rules: ["FREQ=WEEKLY"]
      })

    exception =
      event_fixture(calendar, collection, %{
        resource_id: resource.id,
        recurrence_id: "20261017T100000"
      })

    {:ok, view, _} = live(conn, ~p"/calendars/#{calendar.id}/events/#{exception.id}")
    assert has_element?(view, "#delete-event-component", "Delete component")
    assert has_element?(view, "#delete-event-series", "Delete whole series")
    render_click(view, "delete-event", %{"scope" => "component"})
    assert Calendars.get_event(exception.id) == nil
    assert Calendars.get_event(master.id)
    assert Repo.get!(DAVResource, resource.id).operation == "upsert"
    {:ok, view, _} = live(conn, ~p"/calendars/#{calendar.id}/events/#{master.id}")
    render_click(view, "delete-event", %{"scope" => "series"})
    assert Repo.get!(DAVResource, resource.id).operation == "delete"
    assert Repo.get!(DAVResource, resource.id).status == "pending"
    assert Repo.get!(CalendarEvent, master.id).deleted_at
  end

  test "event conflicts expose full-resource choices and local resolution keeps the draft", %{
    conn: conn
  } do
    {calendar, collection} = imported_calendar_fixture(true)

    resource =
      Repo.insert!(%DAVResource{
        kind: "calendars",
        account_id: calendar.account_id,
        connection_id: collection.connection_id,
        collection_id: collection.id,
        href: "https://caldav.icloud.com/calendar/meeting.ics",
        uid: "meeting",
        base_raw: "base",
        remote_raw: "remote",
        remote_etag: "\"remote\"",
        desired_revision: 1,
        status: "conflict"
      })

    event =
      event_fixture(calendar, collection, %{resource_id: resource.id, summary: "Local draft"})

    {:ok, view, _} = live(conn, ~p"/calendars/#{calendar.id}/events/#{event.id}")
    assert has_element?(view, "#event-conflict", "complete calendar resource")
    view |> element("#event-use-local") |> render_click()
    assert Repo.get!(DAVResource, resource.id).status == "pending"
    assert Calendars.get_event(event.id).summary == "Local draft"
  end

  test "an event from another calendar cannot be shown under the selected source", %{conn: conn} do
    {calendar, _} = imported_calendar_fixture(false)
    {another, collection} = imported_calendar_fixture(false)
    event = event_fixture(another, collection, %{summary: "Other calendar"})

    assert {:error, {:live_redirect, %{to: "/calendars"}}} =
             live(conn, ~p"/calendars/#{calendar.id}/events/#{event.id}")
  end

  defp imported_calendar_fixture(writable) do
    name = "cal#{System.unique_integer([:positive])}.example.test"
    domain = Repo.insert!(%Manifold.Accounts.Schema.Domain{name: name, normalized_domain: name})

    account =
      Repo.insert!(%Manifold.Accounts.Schema.Account{
        domain_id: domain.id,
        local_part: "ada",
        canonical_local_part: "ada"
      })

    connection =
      Repo.insert!(%ICloudConnection{
        account_id: account.id,
        apple_id: "calendar@example.test",
        password_ciphertext: <<1, 2, 3>>
      })

    collection =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "calendars",
        href: "https://caldav.icloud.com/calendar/",
        name: "Work",
        writable: writable
      })

    calendar =
      Repo.insert!(%Calendar{account_id: account.id, collection_id: collection.id, name: "Work"})

    {calendar, collection}
  end

  test "mapping a populated local calendar explicitly merges an occupied iCloud destination", %{
    conn: conn
  } do
    {destination, collection} = imported_calendar_fixture(true)

    resource =
      Repo.insert!(%DAVResource{
        kind: "calendars",
        account_id: destination.account_id,
        connection_id: collection.connection_id,
        collection_id: collection.id,
        href: "https://caldav.icloud.com/calendar/meeting.ics",
        uid: "meeting",
        base_raw: "original ICS",
        etag: "\"baseline\"",
        status: "synced"
      })

    imported = event_fixture(destination, collection, %{resource_id: resource.id})

    {:ok, source} =
      Calendars.create_calendar(%{
        name: "Local draft calendar",
        account_id: destination.account_id
      })

    {:ok, local} =
      Calendars.create_event(%{
        calendar_id: source.id,
        starts_at: "20261011",
        summary: "Offline event"
      })

    {:ok, view, _} = live(conn, ~p"/calendars/#{source.id}/edit")
    refute has_element?(view, "#calendar-merge-destination")

    view
    |> form("#calendar-form", calendar: %{collection_id: collection.id})
    |> render_change()

    assert has_element?(view, "#calendar-merge-destination", "")
    assert render(view) =~ "Merge the existing local calendar for this iCloud destination"
    view |> form("#calendar-form") |> render_submit()
    assert render(view) =~ "Confirm the merge"
    assert Calendars.get_calendar(destination.id)

    view
    |> form("#calendar-form", calendar: %{merge_destination: "true"})
    |> render_submit()

    assert_patch(view, ~p"/calendars/#{source.id}")
    assert Calendars.get_calendar(destination.id) == nil
    assert Calendars.get_event(imported.id).calendar_id == source.id
    assert Repo.get!(DAVResource, resource.id) == resource
    assert Calendars.get_event(local.id).resource.status == "pending"
    assert has_element?(view, "#event-#{imported.id}")
    assert has_element?(view, "#event-#{local.id}")
  end

  test "deleted event conflicts remain accessible and block removal of the containing local calendar",
       %{conn: conn} do
    {calendar, collection} = imported_calendar_fixture(true)

    resource =
      Repo.insert!(%DAVResource{
        kind: "calendars",
        account_id: calendar.account_id,
        connection_id: collection.connection_id,
        collection_id: collection.id,
        href: "https://caldav.icloud.com/calendar/meeting.ics",
        uid: "meeting",
        base_raw: "base",
        remote_raw: "remote",
        remote_etag: "\"remote\"",
        desired_revision: 1,
        operation: "delete",
        status: "conflict"
      })

    event =
      event_fixture(calendar, collection, %{
        resource_id: resource.id,
        deleted_at: DateTime.utc_now()
      })

    assert Calendars.get_event(event.id) == nil
    assert {:error, :sync_pending} = Calendars.delete_calendar(calendar.id)
    {:ok, view, _} = live(conn, ~p"/calendars/#{calendar.id}")
    assert has_element?(view, "#event-#{event.id}", "Deletion conflict")
    render_click(view, "delete-calendar")
    assert render(view) =~ "Pending synchronization and conflicts must finish"
    view |> element("#event-#{event.id} a") |> render_click()
    assert has_element?(view, "#event-conflict")
    refute has_element?(view, "#edit-event")
    view |> element("#event-use-local") |> render_click()
    assert_patch(view, ~p"/calendars/#{calendar.id}")
    assert Repo.get!(DAVResource, resource.id).status == "pending"
    assert Repo.get!(CalendarEvent, event.id).deleted_at
  end

  defp event_fixture(calendar, collection, attrs) do
    defaults = %{
      calendar_id: calendar.id,
      collection_id: collection.id,
      resource_href: "https://caldav.icloud.com/calendar/meeting.ics",
      uid: "meeting",
      summary: "Planning",
      starts_at: "20261010T100000",
      raw: "original ICS"
    }

    Repo.insert!(struct(CalendarEvent, Map.merge(defaults, attrs)))
  end
end

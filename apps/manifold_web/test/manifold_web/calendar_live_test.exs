defmodule ManifoldWeb.CalendarLiveTest do
  use ManifoldWeb.ConnCase, async: true

  alias Manifold.Data.Schema.{CalendarEvent, DAVCollection, ICloudConnection}
  alias Manifold.Repo

  test "empty calendars explain connection setup and recurrence limitations", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/calendars")
    assert has_element?(view, "#calendars-empty")
    assert has_element?(view, "#calendar-recurrence-help", "does not expand")
    assert has_element?(view, "a[href='/settings/icloud']")
  end

  test "event details preserve all-day timezone recurrence and escaped text", %{conn: conn} do
    connection =
      Repo.insert!(%ICloudConnection{
        apple_id: "calendar@example.test",
        password_ciphertext: <<1, 2, 3>>
      })

    calendar =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "calendars",
        href: "https://caldav.icloud.com/calendar/",
        name: "Work"
      })

    event =
      Repo.insert!(%CalendarEvent{
        collection_id: calendar.id,
        resource_href: "https://caldav.icloud.com/calendar/event.ics",
        uid: "meeting",
        recurrence_id: "20261010",
        summary: "Planning <script>",
        starts_at: "20261010",
        ends_at: "20261011",
        timezone: "Europe/London",
        all_day: true,
        location: "Office",
        description: "Notes <script>alert(1)</script>",
        recurrence_rules: ["FREQ=WEEKLY;COUNT=4"],
        excluded_dates: ["20261017"],
        raw: "BEGIN:VCALENDAR\nEND:VCALENDAR"
      })

    {:ok, view, html} = live(conn, ~p"/calendars/#{calendar.id}/events/#{event.id}")
    assert has_element?(view, "#calendar-event-detail", "Read-only")
    assert has_element?(view, "#calendar-event-detail", "Europe/London")
    assert has_element?(view, "#calendar-event-detail", "FREQ=WEEKLY;COUNT=4")
    assert has_element?(view, "#calendar-event-detail", "Recurrence exception ID")
    assert has_element?(view, "#calendar-event-detail", "20261017")
    assert has_element?(view, "#calendar-events", "All day")
    refute html =~ "<script>alert(1)</script>"
    refute has_element?(view, "#calendar-event-detail form")
  end

  test "an event from another calendar cannot be shown under the selected source", %{conn: conn} do
    connection =
      Repo.insert!(%ICloudConnection{
        apple_id: "calendar@example.test",
        password_ciphertext: <<1, 2, 3>>
      })

    calendar =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "calendars",
        href: "https://caldav.icloud.com/one/",
        name: "One"
      })

    another =
      Repo.insert!(%DAVCollection{
        connection_id: connection.id,
        kind: "calendars",
        href: "https://caldav.icloud.com/two/",
        name: "Two"
      })

    event =
      Repo.insert!(%CalendarEvent{
        collection_id: another.id,
        resource_href: "https://caldav.icloud.com/two/event.ics",
        uid: "secret-event",
        summary: "Other calendar",
        starts_at: "20261010",
        raw: "BEGIN:VCALENDAR\nEND:VCALENDAR"
      })

    assert {:error, {:live_redirect, %{to: "/calendars"}}} =
             live(conn, ~p"/calendars/#{calendar.id}/events/#{event.id}")
  end
end

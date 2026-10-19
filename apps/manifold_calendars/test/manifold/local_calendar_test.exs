defmodule Manifold.LocalCalendarTest do
  use Manifold.DataCase, async: true
  alias Manifold.Calendars
  alias Manifold.Data.Schema.{Calendar, CalendarBinding, CalendarConnection, CalendarEvent}

  test "local calendar identity is independent of mailbox and binding settings" do
    assert {:ok, calendar} = Calendars.create_calendar(%{name: "Local"})
    assert is_nil(calendar.account_id)

    assert {:error, :use_sync_bindings} =
             Calendars.update_calendar(calendar.id, %{collection_id: Ecto.UUID.generate()})

    assert {:ok, renamed} = Calendars.update_calendar(calendar.id, %{name: "Work"})
    assert renamed.id == calendar.id
  end

  test "offline edits retain a revision and reject stale saves" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Local"})

    {:ok, event} =
      Calendars.create_event(%{calendar_id: calendar.id, starts_at: "20261019", summary: "One"})

    assert event.series_id
    assert event.time_kind == "date"

    assert {:ok, revised} =
             Calendars.update_event(event.id, %{summary: "Two"}, expected_revision: 1)

    assert revised.local_revision == 2

    assert {:error, :stale} =
             Calendars.update_event(event.id, %{summary: "Lost"}, expected_revision: 1)

    assert Calendars.get_event(event.id).summary == "Two"
  end

  test "old recurring master appears in a later month in the viewing timezone" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Local"})

    {:ok, event} =
      Calendars.create_event(%{
        calendar_id: calendar.id,
        starts_at: "20260101T233000Z",
        ends_at: "20260102T003000Z",
        recurrence_rules: ["FREQ=DAILY"]
      })

    assert {:ok, occurrences} =
             Calendars.list_occurrences([calendar.id],
               from: ~D[2026-10-20],
               until: ~D[2026-10-21],
               timezone: "Asia/Shanghai"
             )

    assert [%{event_id: id, date: ~D[2026-10-20], clock: "07:30"}] = occurrences
    assert id == event.id
  end

  test "delete one occurrence excludes the original slot including a moved exception" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Local"})

    {:ok, master} =
      Calendars.create_event(%{
        calendar_id: calendar.id,
        starts_at: "20261001T100000Z",
        ends_at: "20261001T110000Z",
        recurrence_rules: ["FREQ=DAILY;COUNT=5"]
      })

    assert {:ok, exception} =
             Calendars.update_occurrence(master.id, "20261002T100000Z", %{
               starts_at: "20261003T140000Z",
               ends_at: "20261003T150000Z"
             })

    assert exception.series_id == master.series_id
    assert exception.recurrence_id == "20261002T100000Z"
    assert {:ok, _} = Calendars.delete_event(exception.id, scope: :occurrence)

    assert {:ok, occurrences} =
             Calendars.list_occurrences([calendar.id],
               from: ~D[2026-10-01],
               until: ~D[2026-10-07]
             )

    refute Enum.any?(occurrences, &(&1.recurrence_id == "20261002T100000Z"))
    assert length(occurrences) == 4
    assert Repo.get!(CalendarEvent, exception.id).deleted_at
  end

  test "copying a series creates independent identity and preserves rule and exception" do
    {:ok, source} = Calendars.create_calendar(%{name: "Source"})
    {:ok, target} = Calendars.create_calendar(%{name: "Copy"})

    {:ok, master} =
      Calendars.create_event(%{
        calendar_id: source.id,
        starts_at: "20261001",
        ends_at: "20261002",
        recurrence_rules: ["FREQ=DAILY;COUNT=3"],
        excluded_dates: ["20261003"],
        reminders: [%{"method" => "popup", "minutes" => 15}]
      })

    {:ok, _} = Calendars.update_occurrence(master.id, "20261002", %{summary: "Exception"})

    assert {:ok, copy} =
             Calendars.copy_event(master.id, %{calendar_id: target.id}, scope: :series)

    assert copy.series_id != master.series_id
    assert copy.uid != master.uid
    assert copy.recurrence_rules == master.recurrence_rules
    assert copy.excluded_dates == master.excluded_dates
    assert copy.reminders == master.reminders
    assert length(Calendars.list_events(target.id)) == 2
  end

  test "local calendar deletion archives binding identity and keeps request evidence" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Local"})
    {:ok, event} = Calendars.create_event(%{calendar_id: calendar.id, starts_at: "20261019"})
    connection = Repo.insert!(%CalendarConnection{provider: "google", status: "active"})

    binding =
      Repo.insert!(%CalendarBinding{
        calendar_id: calendar.id,
        connection_id: connection.id,
        remote_calendar_id: "remote",
        state: "active"
      })

    assert {:ok, _} = Calendars.delete_calendar(calendar.id)
    assert is_nil(Calendars.get_calendar(calendar.id))
    assert Calendars.list_calendars() == []
    assert Repo.get!(Calendar, calendar.id).deleted_at
    assert Repo.get!(CalendarEvent, event.id).deleted_at == nil
    archived = Repo.get!(CalendarBinding, binding.id)
    assert archived.state == "detached"
    assert archived.suppressed_at
    assert archived.remote_calendar_id == "remote"
  end

  test "local reminders reject invalid values and normalize equivalent ordering" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Reminders"})

    assert {:error, %Ecto.Changeset{}} =
             Calendars.create_event(calendar.id, %{
               starts_at: "20261019",
               reminders: [%{"method" => "audio", "minutes" => -1}]
             })

    assert {:ok, event} =
             Calendars.create_event(calendar.id, %{
               starts_at: "20261019",
               reminders: [
                 %{"method" => "popup", "minutes" => 30},
                 %{"method" => "popup", "minutes" => 5},
                 %{"method" => "popup", "minutes" => 5}
               ]
             })

    assert event.reminders == [
             %{"method" => "popup", "minutes" => 5},
             %{"method" => "popup", "minutes" => 30}
           ]
  end

  test "nil and malformed reminders return validation errors without changing local events" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Reminders"})
    reminders = [%{"method" => "popup", "minutes" => 15}]

    {:ok, event} =
      Calendars.create_event(calendar.id, %{starts_at: "20261019", reminders: reminders})

    for invalid <- [
          nil,
          [nil],
          "invalid",
          %{},
          1,
          ["invalid"],
          [%{}],
          [%{"method" => "popup", "minutes" => "15"}]
        ] do
      assert {:error, %Ecto.Changeset{} = create_changeset} =
               Calendars.create_event(calendar.id, %{starts_at: "20261019", reminders: invalid})

      assert Keyword.has_key?(create_changeset.errors, :reminders)

      assert {:error, %Ecto.Changeset{} = update_changeset} =
               Calendars.update_event(event.id, %{reminders: invalid})

      assert Keyword.has_key?(update_changeset.errors, :reminders)
    end

    assert Calendars.get_event(event.id).reminders == reminders
    assert Calendars.get_event(event.id).local_revision == event.local_revision
    assert length(Calendars.list_events(calendar.id)) == 1
    assert {:ok, cleared} = Calendars.update_event(event.id, %{reminders: []})
    assert cleared.reminders == []
  end

  test "editing and copying a moved occurrence preserve its revision and moved time" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Local"})

    {:ok, master} =
      Calendars.create_event(calendar.id, %{
        starts_at: "20261001T100000Z",
        ends_at: "20261001T110000Z",
        recurrence_rules: ["FREQ=DAILY;COUNT=3"]
      })

    {:ok, exception} =
      Calendars.update_occurrence(master.id, "20261002T100000Z", %{
        starts_at: "20261002T140000Z",
        ends_at: "20261002T150000Z",
        summary: "Moved"
      })

    assert {:ok, edited} =
             Calendars.update_occurrence(
               exception.id,
               exception.recurrence_id,
               %{summary: "Edited"},
               expected_revision: exception.local_revision
             )

    assert {:error, :stale} =
             Calendars.update_occurrence(
               exception.id,
               exception.recurrence_id,
               %{summary: "Stale"},
               expected_revision: exception.local_revision
             )

    assert {:ok, copy} =
             Calendars.copy_event(edited.id, %{},
               scope: :occurrence,
               recurrence_id: edited.recurrence_id
             )

    assert copy.starts_at == "20261002T140000Z"
    assert copy.ends_at == "20261002T150000Z"
    assert copy.summary == "Edited"
    assert copy.recurrence_id == ""
    assert copy.recurrence_rules == []
    assert copy.series_id != master.series_id
  end
end

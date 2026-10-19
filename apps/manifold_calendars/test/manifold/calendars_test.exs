defmodule Manifold.CalendarsTest do
  use Manifold.DataCase, async: true
  alias Manifold.Calendars

  alias Manifold.Data.Schema.{
    Calendar,
    CalendarEvent,
    CalendarConnection,
    CalendarBinding,
    CalendarEventBinding
  }

  test "invalid IDs cannot select unrelated calendars or events" do
    for id <- [nil, "", "invalid", Ecto.UUID.generate()] do
      assert Calendars.get_calendar(id) == nil
      assert Calendars.get_event(id) == nil
      assert Calendars.list_events(id) == []
    end
  end

  test "local commands validate actual date intervals and preserve offline data" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Local"})

    for attrs <- [
          %{},
          %{starts_at: "invalid"},
          %{starts_at: "20260230"},
          %{starts_at: "20261019", ends_at: "20261018"},
          %{starts_at: "20261019", all_day: false},
          %{starts_at: "20261019T250000"}
        ] do
      assert {:error, %Ecto.Changeset{}} =
               Calendars.create_event(Map.put(attrs, :calendar_id, calendar.id))
    end

    assert Calendars.list_events(calendar.id) == []

    assert {:error, :calendar_not_found} =
             Calendars.create_event(%{calendar_id: Ecto.UUID.generate(), starts_at: "20261019"})

    assert {:ok, event} =
             Calendars.create_event(calendar.id, %{
               starts_at: "20261019T100000",
               ends_at: "20261019T110000"
             })

    assert event.time_kind == "floating"
    assert event.timezone == nil

    assert {:ok, utc} =
             Calendars.update_event(event.id, %{
               starts_at: "20261019T100000Z",
               ends_at: "20261019T110000Z"
             })

    assert utc.time_kind == "utc"
    assert utc.local_revision == 2
  end

  test "calendar settings never move rows or adopt another calendar" do
    {:ok, one} = Calendars.create_calendar(%{name: "One"})
    {:ok, two} = Calendars.create_calendar(%{name: "Two"})
    {:ok, event} = Calendars.create_event(one.id, %{starts_at: "20261019"})

    assert {:error, :use_sync_bindings} =
             Calendars.update_calendar(one.id, %{
               collection_id: Ecto.UUID.generate(),
               merge_destination: true
             })

    assert {:error, :copy_required} = Calendars.update_event(event.id, %{calendar_id: two.id})
    assert Calendars.get_event(event.id).calendar_id == one.id

    assert MapSet.new(Enum.map(Calendars.list_calendars(), & &1.id)) ==
             MapSet.new([one.id, two.id])
  end

  test "record pagination is independent from occurrence range queries" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Many"})

    for index <- 1..55,
        do: Calendars.create_event(calendar.id, %{starts_at: "20200101", summary: "Old #{index}"})

    {:ok, recent} =
      Calendars.create_event(calendar.id, %{starts_at: "20261019", summary: "Recent"})

    assert length(Calendars.list_events(calendar.id, limit: 50)) == 50
    assert length(Calendars.list_events(calendar.id, limit: 50, offset: 50)) == 6

    assert {:ok, [%{event_id: id}]} =
             Calendars.list_occurrences([calendar.id],
               from: ~D[2026-10-01],
               until: ~D[2026-11-01]
             )

    assert id == recent.id

    assert {:error, _} =
             Calendars.list_occurrences([calendar.id],
               from: ~D[2026-11-01],
               until: ~D[2026-10-01]
             )
  end

  test "read-only provenance needs an explicit independent copy" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Imported"})

    source =
      Repo.insert!(%CalendarEvent{
        calendar_id: calendar.id,
        uid: "source",
        series_id: Ecto.UUID.generate(),
        starts_at: "20261019",
        all_day: true,
        read_only: true,
        raw: "retained original"
      })

    assert {:error, :read_only} = Calendars.update_event(source.id, %{summary: "Unsafe"})
    assert {:error, :read_only} = Calendars.delete_event(source.id)
    assert {:ok, copy} = Calendars.copy_event(source.id, %{calendar_id: calendar.id})
    refute copy.read_only
    assert copy.uid != source.uid
    assert copy.series_id != source.series_id
    assert copy.raw == nil
    assert {:ok, _} = Calendars.update_event(copy.id, %{summary: "Independent"})
    assert Repo.get!(CalendarEvent, source.id).raw == source.raw
  end

  test "deleting the series requires explicit scope and retains every component tombstone" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Series"})

    {:ok, master} =
      Calendars.create_event(calendar.id, %{
        starts_at: "20261001",
        recurrence_rules: ["FREQ=DAILY;COUNT=3"]
      })

    {:ok, exception} = Calendars.update_occurrence(master.id, "20261002", %{summary: "Exception"})
    assert {:error, :scope_required} = Calendars.delete_event(master.id)
    assert {:ok, _} = Calendars.delete_event(master.id, scope: :series)
    assert Calendars.list_events(calendar.id) == []
    assert Repo.get!(CalendarEvent, master.id).deleted_at
    assert Repo.get!(CalendarEvent, exception.id).deleted_at
  end

  test "sync summaries retain independent pending and conflict counts without exposing credentials" do
    {:ok, calendar} = Calendars.create_calendar(%{name: "Shared"})
    {:ok, event} = Calendars.create_event(calendar.id, %{starts_at: "20261019"})

    for provider <- ["google", "icloud"] do
      c =
        Repo.insert!(%CalendarConnection{provider: provider, encrypted_credentials: <<1, 2, 3>>})

      b =
        Repo.insert!(%CalendarBinding{
          calendar_id: calendar.id,
          connection_id: c.id,
          remote_calendar_id: provider,
          state: "paused"
        })

      r =
        Repo.insert!(%Manifold.Data.Schema.CalendarSyncResource{
          binding_id: b.id,
          remote_resource_id: "event"
        })

      Repo.insert!(%CalendarEventBinding{
        binding_id: b.id,
        event_id: event.id,
        resource_id: r.id,
        remote_component_key: "event",
        desired_revision: 1,
        acknowledged_revision: if(provider == "google", do: 1, else: 0)
      })
    end

    summaries = Calendars.sync_summary(calendar.id)
    assert Enum.sort(Enum.map(summaries, & &1.pending)) == [0, 1]
    assert Enum.all?(summaries, &is_nil(&1.binding.connection.encrypted_credentials))
    assert Repo.get!(Calendar, calendar.id).id == calendar.id
  end
end

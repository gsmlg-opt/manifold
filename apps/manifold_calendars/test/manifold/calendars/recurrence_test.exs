defmodule Manifold.Calendars.RecurrenceTest do
  use ExUnit.Case, async: true

  alias Manifold.Calendars.Recurrence

  defp event(attrs) do
    Map.merge(
      %{
        id: "master",
        calendar_id: "calendar",
        uid: "uid",
        recurrence_id: "",
        starts_at: "20260101T090000Z",
        ends_at: "20260101T100000Z",
        timezone: nil,
        all_day: false,
        recurrence_rules: [],
        recurrence_dates: [],
        excluded_dates: [],
        deleted_at: nil,
        local_revision: 1
      },
      attrs
    )
  end

  test "old daily master expands across months in the viewing zone" do
    master = event(%{recurrence_rules: ["FREQ=DAILY"]})

    assert {:ok, [first, second]} =
             Recurrence.occurrences([master], ~D[2026-10-19], ~D[2026-10-21], "Asia/Shanghai")

    assert %{
             event_id: "master",
             master_id: "master",
             recurrence_id: "20261019T090000Z",
             date: ~D[2026-10-19],
             clock: "17:00"
           } = first

    assert second.recurrence_id == "20261020T090000Z"
  end

  test "all-day end is exclusive and an overlap from the preceding month is included" do
    master = event(%{starts_at: "20260930", ends_at: "20261002", all_day: true})

    assert {:ok, [%{date: ~D[2026-09-30], clock: "All day"}]} =
             Recurrence.occurrences([master], ~D[2026-10-01], ~D[2026-10-02], "Asia/Shanghai")

    assert {:ok, []} =
             Recurrence.occurrences([master], ~D[2026-10-02], ~D[2026-10-03], "Asia/Shanghai")
  end

  test "viewing timezone governs range membership and exact midnight is exclusive" do
    master = event(%{starts_at: "20261019T153000Z", ends_at: "20261019T160000Z"})

    assert {:ok, [%{date: ~D[2026-10-19], clock: "23:30"}]} =
             Recurrence.occurrences([master], ~D[2026-10-19], ~D[2026-10-20], "Asia/Shanghai")

    assert {:ok, []} =
             Recurrence.occurrences([master], ~D[2026-10-20], ~D[2026-10-21], "Asia/Shanghai")
  end

  test "RDATE union and EXDATE subtraction deduplicate equal starts" do
    master =
      event(%{
        recurrence_rules: ["FREQ=DAILY;COUNT=3"],
        recurrence_dates: ["20260102T090000Z,20260105T090000Z"],
        excluded_dates: ["20260102T090000Z"]
      })

    assert {:ok, occurrences} = Recurrence.occurrences([master], ~D[2026-01-01], ~D[2026-01-07])

    assert Enum.map(occurrences, & &1.recurrence_id) == [
             "20260101T090000Z",
             "20260103T090000Z",
             "20260105T090000Z"
           ]
  end

  test "RDATE and EXDATE retain explicit TZID parameters" do
    master =
      event(%{
        starts_at: "20260101T140000Z",
        ends_at: "20260101T150000Z",
        recurrence_dates: ["RDATE;TZID=America/New_York:20260102T090000"],
        excluded_dates: ["EXDATE;TZID=America/New_York:20260101T090000"]
      })

    assert {:ok, [%{starts_at: ~U[2026-01-02 14:00:00Z]}]} =
             Recurrence.occurrences([master], ~D[2026-01-01], ~D[2026-01-03])
  end

  test "moved exception replaces original identity even when moved across query boundary" do
    master = event(%{recurrence_rules: ["FREQ=DAILY;COUNT=2"]})

    exception =
      event(%{
        id: "exception",
        recurrence_id: "20260102T090000Z",
        starts_at: "20260201T110000Z",
        ends_at: "20260201T120000Z"
      })

    assert {:ok, [%{recurrence_id: "20260101T090000Z"}]} =
             Recurrence.occurrences([master, exception], ~D[2026-01-01], ~D[2026-01-03])

    assert {:ok,
            [
              %{
                event_id: "exception",
                master_id: "master",
                recurrence_id: "20260102T090000Z",
                clock: "11:00"
              }
            ]} = Recurrence.occurrences([master, exception], ~D[2026-02-01], ~D[2026-02-02])
  end

  test "deleted exception suppresses occurrence without resurrecting master" do
    master = event(%{recurrence_rules: ["FREQ=DAILY;COUNT=2"]})

    exception =
      event(%{
        id: "deleted",
        recurrence_id: "20260102T090000Z",
        deleted_at: ~U[2026-01-01 12:00:00Z]
      })

    assert {:ok, [%{recurrence_id: "20260101T090000Z"}]} =
             Recurrence.occurrences([master, exception], ~D[2026-01-01], ~D[2026-01-03])
  end

  test "same UID in different local calendars does not share exceptions" do
    master = event(%{recurrence_rules: ["FREQ=DAILY;COUNT=1"]})

    other =
      event(%{
        id: "other",
        calendar_id: "other-calendar",
        recurrence_rules: ["FREQ=DAILY;COUNT=1"]
      })

    exception =
      event(%{
        id: "deleted",
        recurrence_id: "20260101T090000Z",
        deleted_at: ~U[2026-01-01 12:00:00Z]
      })

    assert {:ok, [%{event_id: "other"}]} =
             Recurrence.occurrences([master, other, exception], ~D[2026-01-01], ~D[2026-01-02])
  end

  test "TZID daily recurrence retains local clock across spring DST" do
    master =
      event(%{
        starts_at: "20260307T090000",
        ends_at: "20260307T100000",
        timezone: "America/New_York",
        recurrence_rules: ["FREQ=DAILY;COUNT=3"]
      })

    assert {:ok, occurrences} = Recurrence.occurrences([master], ~D[2026-03-07], ~D[2026-03-10])

    assert Enum.map(occurrences, & &1.starts_at) == [
             ~U[2026-03-07 14:00:00Z],
             ~U[2026-03-08 13:00:00Z],
             ~U[2026-03-09 13:00:00Z]
           ]

    assert Enum.map(occurrences, & &1.recurrence_id) == [
             "20260307T090000",
             "20260308T090000",
             "20260309T090000"
           ]
  end

  test "floating recurrence is expanded in the viewing zone" do
    master =
      event(%{
        starts_at: "20260307T090000",
        ends_at: "20260307T100000",
        recurrence_rules: ["FREQ=DAILY;COUNT=3"]
      })

    assert {:ok, occurrences} =
             Recurrence.occurrences([master], ~D[2026-03-07], ~D[2026-03-10], "America/New_York")

    assert Enum.map(occurrences, & &1.clock) == ["09:00", "09:00", "09:00"]
  end

  test "yearly ordinal BYDAY and BYSETPOS use the recurrence library" do
    master =
      event(%{
        starts_at: "20200101T090000Z",
        ends_at: "20200101T100000Z",
        recurrence_rules: ["FREQ=YEARLY;BYMONTH=10;BYDAY=MO,TU,WE,TH,FR;BYSETPOS=-1"]
      })

    assert {:ok, [%{recurrence_id: "20261030T090000Z"}]} =
             Recurrence.occurrences([master], ~D[2026-10-01], ~D[2026-11-01])
  end

  test "unsupported or invalid rules return event-scoped errors" do
    master = event(%{recurrence_rules: ["FREQ=UNKNOWN"]})

    assert {:error, [%{event_id: "master", reason: {:invalid_recurrence_rule, _}}]} =
             Recurrence.occurrences([master], ~D[2026-01-01], ~D[2026-01-02])
  end

  test "bounded expansion reports truncation instead of silently omitting instances" do
    master = event(%{recurrence_rules: ["FREQ=SECONDLY"]})

    assert {:error, [%{reason: :recurrence_limit_exceeded}]} =
             Recurrence.occurrences([master], ~D[2026-01-01], ~D[2026-01-03])
  end

  test "all-day recurrence preserves date UNTIL and exclusive multi-day duration" do
    master =
      event(%{
        starts_at: "20260101",
        ends_at: "20260103",
        all_day: true,
        recurrence_rules: ["FREQ=DAILY;UNTIL=20260103"]
      })

    assert {:ok, occurrences} =
             Recurrence.occurrences(
               [master],
               ~D[2026-01-02],
               ~D[2026-01-05],
               "America/Los_Angeles"
             )

    assert Enum.map(occurrences, &{&1.starts_at, &1.ends_at}) == [
             {~D[2026-01-01], ~D[2026-01-03]},
             {~D[2026-01-02], ~D[2026-01-04]},
             {~D[2026-01-03], ~D[2026-01-05]}
           ]
  end

  test "generated nonexistent local times are skipped without consuming COUNT" do
    master =
      event(%{
        starts_at: "20260307T023000",
        ends_at: "20260307T033000",
        timezone: "America/New_York",
        recurrence_rules: ["FREQ=DAILY;COUNT=3"]
      })

    assert {:ok, occurrences} =
             Recurrence.occurrences([master], ~D[2026-03-07], ~D[2026-03-12], "America/New_York")

    assert Enum.map(occurrences, & &1.recurrence_id) == [
             "20260307T023000",
             "20260309T023000",
             "20260310T023000"
           ]
  end

  test "fall DST keeps first-fold identity and a fixed timed event duration" do
    master =
      event(%{
        starts_at: "20261031T013000",
        ends_at: "20261031T023000",
        timezone: "America/New_York",
        recurrence_rules: ["FREQ=DAILY;COUNT=3"]
      })

    assert {:ok, [_, fold, _]} = Recurrence.occurrences([master], ~D[2026-10-31], ~D[2026-11-03])
    assert fold.starts_at == ~U[2026-11-01 05:30:00Z]
    assert DateTime.diff(fold.ends_at, fold.starts_at) == 3600
  end

  test "EXDATE with a different temporal type produces an explicit error" do
    master = event(%{recurrence_rules: ["FREQ=DAILY"], excluded_dates: ["20260102"]})

    assert {:error, [%{reason: :mixed_calendar_time_types}]} =
             Recurrence.occurrences([master], ~D[2026-01-01], ~D[2026-01-03])
  end

  test "exception recurrence zone remains independent of its moved DTSTART zone" do
    master =
      event(%{
        starts_at: "20260101T090000",
        ends_at: "20260101T100000",
        timezone: "America/New_York",
        recurrence_rules: ["FREQ=DAILY;COUNT=2"]
      })

    exception =
      event(%{
        id: "moved-zone",
        starts_at: "20260102T180000",
        ends_at: "20260102T190000",
        timezone: "Asia/Shanghai",
        recurrence_timezone: "America/New_York",
        recurrence_id: "20260102T090000"
      })

    assert {:ok,
            [
              _,
              %{
                event_id: "moved-zone",
                starts_at: ~U[2026-01-02 10:00:00Z],
                recurrence_id: "20260102T090000"
              }
            ]} = Recurrence.occurrences([master, exception], ~D[2026-01-01], ~D[2026-01-03])
  end

  test "same-calendar identical UIDs retain independent canonical series identities" do
    first = event(%{series_id: "series-one", recurrence_rules: ["FREQ=DAILY;COUNT=1"]})

    second =
      event(%{id: "second", series_id: "series-two", recurrence_rules: ["FREQ=DAILY;COUNT=1"]})

    deleted =
      event(%{
        id: "deleted",
        series_id: "series-one",
        recurrence_id: "20260101T090000Z",
        deleted_at: ~U[2026-01-01 12:00:00Z]
      })

    assert {:ok, [%{event_id: "second"}]} =
             Recurrence.occurrences([first, second, deleted], ~D[2026-01-01], ~D[2026-01-02])
  end

  test "UTC UNTIL is inclusive after applying the source timezone" do
    master =
      event(%{
        starts_at: "20260307T090000",
        ends_at: "20260307T100000",
        timezone: "America/New_York",
        recurrence_rules: ["FREQ=DAILY;UNTIL=20260308T130000Z"]
      })

    assert {:ok, occurrences} = Recurrence.occurrences([master], ~D[2026-03-07], ~D[2026-03-10])

    assert Enum.map(occurrences, & &1.starts_at) == [
             ~U[2026-03-07 14:00:00Z],
             ~U[2026-03-08 13:00:00Z]
           ]
  end

  test "recurrence master at a DST fold still uses RFC first-occurrence interpretation" do
    master =
      event(%{
        starts_at: "20261101T013000",
        ends_at: "20261101T023000",
        timezone: "America/New_York",
        recurrence_rules: ["FREQ=DAILY;COUNT=2"]
      })

    assert {:ok, [first, second]} =
             Recurrence.occurrences([master], ~D[2026-11-01], ~D[2026-11-03])

    assert first.starts_at == ~U[2026-11-01 05:30:00Z]
    assert second.starts_at == ~U[2026-11-02 06:30:00Z]
  end

  test "invalid ranges return an explicit error" do
    assert {:error, [%{reason: :invalid_range}]} =
             Recurrence.occurrences([], ~D[2026-01-02], ~D[2026-01-01])
  end
end

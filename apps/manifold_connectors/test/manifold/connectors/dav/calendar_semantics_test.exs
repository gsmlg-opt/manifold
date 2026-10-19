defmodule Manifold.Connectors.DAV.CalendarSemanticsTest do
  use ExUnit.Case, async: true
  alias Manifold.Connectors.DAV.{Document, ICalendar}

  @raw "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nX-KEEP:calendar\r\nBEGIN:VEVENT\r\nUID:series\r\nDTSTART;TZID=America/New_York:20261001T100000\r\nDTEND;TZID=America/New_York:20261001T110000\r\nRRULE:FREQ=DAILY;COUNT=5\r\nX-KEEP:event\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

  test "parameters of RDATE EXDATE and recurrence ID survive parsing" do
    raw =
      String.replace(
        @raw,
        "X-KEEP:event",
        "RDATE;TZID=America/New_York:20261009T100000\r\nEXDATE;VALUE=DATE:20261003\r\nX-KEEP:event"
      )

    assert {:ok, [event]} = ICalendar.parse(raw)
    assert event.recurrence_dates == ["RDATE;TZID=America/New_York:20261009T100000"]
    assert event.excluded_dates == ["EXDATE;VALUE=DATE:20261003"]
  end

  test "new detached component and recurrence edits preserve unknown content" do
    attrs = %{
      starts_at: "20261003T140000",
      ends_at: "20261003T150000",
      timezone: "America/Chicago",
      recurrence_timezone: "America/New_York",
      summary: "Moved"
    }

    assert {:ok, raw} = Document.event(@raw, attrs, "series", "20261002T100000")
    assert raw =~ "RECURRENCE-ID;TZID=America/New_York:20261002T100000"
    assert raw =~ "X-KEEP:calendar"
    assert raw =~ "X-KEEP:event"

    assert {:ok, raw} =
             Document.event(
               raw,
               %{
                 excluded_dates: ["EXDATE;TZID=America/New_York:20261004T100000"],
                 recurrence_rules: ["FREQ=DAILY;COUNT=7"]
               },
               "series"
             )

    assert raw =~ "RRULE:FREQ=DAILY;COUNT=7"
    assert raw =~ "EXDATE;TZID=America/New_York:20261004T100000"
    assert {:ok, [_master, exception]} = ICalendar.parse(raw)
    assert exception.recurrence_timezone == "America/New_York"
    assert exception.timezone == "America/Chicago"
  end

  test "deleting an occurrence excludes its original slot rather than restoring it" do
    {:ok, raw} =
      Document.event(
        @raw,
        %{starts_at: "20261003T140000", timezone: "America/New_York"},
        "series",
        "20261002T100000"
      )

    assert {:ok, deleted} = Document.delete_event(raw, "series", "20261002T100000")
    assert deleted =~ "EXDATE;TZID=America/New_York:20261002T100000"
    refute deleted =~ "RECURRENCE-ID"
    assert deleted =~ "RRULE:FREQ=DAILY;COUNT=5"
    assert deleted =~ "X-KEEP:event"
  end

  test "cancelled recurrence slots remain explicit tombstones even without DTSTART" do
    raw =
      "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:series\r\nRECURRENCE-ID;TZID=America/New_York:20261002T100000\r\nSTATUS:CANCELLED\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

    assert {:ok, [event]} = ICalendar.parse(raw)
    assert event.deleted
    assert event.recurrence_id == "20261002T100000"
    assert event.recurrence_timezone == "America/New_York"
  end

  test "relative display alarms round-trip as canonical reminders" do
    alarm =
      "BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER;RELATED=START:-P1DT2H\r\nDESCRIPTION:Provider text\r\nEND:VALARM\r\n"

    raw = String.replace(@raw, "END:VEVENT", alarm <> "END:VEVENT")
    assert {:ok, [event]} = ICalendar.parse(raw)
    assert event.reminders == [%{"method" => "popup", "minutes" => 1560}]
    refute event.unsupported_alarms
    assert {:ok, edited} = Document.event(raw, %{summary: "Edited"}, "series")
    assert edited =~ alarm

    assert {:ok, changed} =
             Document.event(
               edited,
               %{reminders: [%{"method" => "popup", "minutes" => 10}]},
               "series"
             )

    assert {:ok, [projected]} = ICalendar.parse(changed)
    assert projected.reminders == [%{"method" => "popup", "minutes" => 10}]
    assert changed =~ "X-KEEP:event"
    assert {:ok, cleared} = Document.event(changed, %{reminders: []}, "series")
    refute cleared =~ "VALARM"
  end

  test "unrepresentable alarms retain their content and reject lossy reminder replacement" do
    alarm =
      "BEGIN:VALARM\r\nACTION:AUDIO\r\nTRIGGER;VALUE=DATE-TIME:20261001T080000Z\r\nATTACH:https://example.test/tone\r\nEND:VALARM\r\n"

    raw = String.replace(@raw, "END:VEVENT", alarm <> "END:VEVENT")
    assert {:ok, [event]} = ICalendar.parse(raw)
    assert event.unsupported_alarms
    assert {:ok, edited} = Document.event(raw, %{summary: "Safe edit"}, "series")
    assert edited =~ alarm

    assert {:error, :unsupported_alarms} =
             Document.event(raw, %{reminders: [%{"method" => "popup", "minutes" => 5}]}, "series")

    assert {:error, :unsupported_alarms} =
             Document.event(
               @raw,
               %{reminders: [%{"method" => "email", "minutes" => 5}]},
               "series"
             )
  end

  test "invalid generated recurrence input returns an error without escaping the boundary" do
    assert {:error, :invalid_document} = Document.event(nil, %{summary: "Missing start"}, "new")

    assert {:error, :invalid_document} =
             Document.event(
               @raw,
               %{recurrence_dates: ["RDATE:20261001\r\nSUMMARY:injected"]},
               "series"
             )
  end
end

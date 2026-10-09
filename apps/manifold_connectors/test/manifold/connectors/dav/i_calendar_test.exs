defmodule Manifold.Connectors.DAV.ICalendarTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.DAV.ICalendar

  test "rejects multiple calendar roots and events outside the calendar" do
    raw =
      "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR\n" <>
        event() <> "BEGIN:VCALENDAR\nEND:VCALENDAR\n"

    assert {:error, _} = ICalendar.parse(raw)

    raw =
      "BEGIN:VCALENDAR\nVERSION:2.0\n" <>
        event() <>
        "END:VCALENDAR\nBEGIN:VCALENDAR\nVERSION:2.0\n" <>
        event("second") <> "END:VCALENDAR\n"

    assert {:error, _} = ICalendar.parse(raw)
  end

  test "requires one VERSION property at the calendar level" do
    nested =
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nVERSION:2.0\nUID:x\nDTSTART:20261010T100000Z\nEND:VEVENT\nEND:VCALENDAR\n"

    assert {:error, _} = ICalendar.parse(nested)
    duplicate = "BEGIN:VCALENDAR\nVERSION:2.0\nVERSION:2.0\n" <> event() <> "END:VCALENDAR\n"
    assert {:error, _} = ICalendar.parse(duplicate)
  end

  test "rejects nested calendar roots and VEVENTs inside other components" do
    nested =
      "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VCALENDAR\n" <>
        event() <> "END:VCALENDAR\nEND:VCALENDAR\n"

    assert {:error, _} = ICalendar.parse(nested)

    nested =
      "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VTODO\n" <> event() <> "END:VTODO\nEND:VCALENDAR\n"

    assert {:error, _} = ICalendar.parse(nested)
  end

  test "does not accept properties outside a completed calendar" do
    raw =
      "BEGIN:VCALENDAR\nVERSION:2.0\n" <>
        event() <>
        "END:VCALENDAR\nSUMMARY:outside\nBEGIN:VCALENDAR\nEND:VCALENDAR\n"

    assert {:error, _} = ICalendar.parse(raw)
  end

  test "retains supported events with timezone and nested alarm components" do
    raw = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VTIMEZONE
    TZID:Asia/Shanghai
    BEGIN:STANDARD
    DTSTART:19700101T000000
    TZOFFSETFROM:+0800
    TZOFFSETTO:+0800
    END:STANDARD
    END:VTIMEZONE
    BEGIN:VEVENT
    UID:meeting
    DTSTART;TZID=Asia/Shanghai:20261010T100000
    SUMMARY:Meeting
    BEGIN:VALARM
    TRIGGER:-PT15M
    ACTION:DISPLAY
    DESCRIPTION:Reminder
    END:VALARM
    END:VEVENT
    END:VCALENDAR
    """

    assert {:ok, [%{uid: "meeting", summary: "Meeting", timezone: "Asia/Shanghai", raw: ^raw}]} =
             ICalendar.parse(raw)
  end

  defp event(uid \\ "x") do
    "BEGIN:VEVENT\nUID:#{uid}\nDTSTART:20261010T100000Z\nEND:VEVENT\n"
  end
end

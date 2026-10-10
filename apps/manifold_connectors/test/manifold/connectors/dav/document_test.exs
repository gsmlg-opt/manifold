defmodule Manifold.Connectors.DAV.DocumentTest do
  use ExUnit.Case, async: true
  alias Manifold.Connectors.DAV.{Document, VCard, ICalendar}

  @card "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:one\r\nFN:Old name\r\nN:Family;Given;Middle;Dr;Jr\r\nitem1.EMAIL;TYPE=HOME;X-UNKNOWN=kept:a@example.org\r\nitem1.X-ABLabel:Private\r\nPHOTO;ENCODING=b:abcdef\r\nX-UNKNOWN:some\r\n thing\r\nEND:VCARD\r\n"
  @ics "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nX-CALENDAR:keep\r\nBEGIN:VTIMEZONE\r\nTZID:Europe/Paris\r\nX-TIMEZONE:keep\r\nEND:VTIMEZONE\r\nBEGIN:VEVENT\r\nUID:event\r\nDTSTART;TZID=Europe/Paris:20261010T100000\r\nSUMMARY:Old\r\nRRULE:FREQ=DAILY\r\nBEGIN:VALARM\r\nACTION:DISPLAY\r\nDESCRIPTION:Alarm\r\nEND:VALARM\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:event\r\nRECURRENCE-ID;TZID=Europe/Paris:20261011T100000\r\nDTSTART;TZID=Europe/Paris:20261011T110000\r\nSUMMARY:Exception\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:sibling\r\nDTSTART:20261012T100000Z\r\nSUMMARY:Sibling\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

  test "server normalization permits managed timestamps and order but preserves unknown content" do
    remote =
      @card
      |> String.replace("VERSION:3.0\r\nUID:one", "UID:one\r\nVERSION:3.0")
      |> String.replace("END:VCARD", "REV:20261010T120000Z\r\nEND:VCARD")

    assert Document.equivalent?(@card, remote)

    remote =
      String.replace(
        @ics,
        "SUMMARY:Old",
        "DTSTAMP:20261010T120000Z\r\nLAST-MODIFIED:20261010T120000Z\r\nSUMMARY:Old"
      )

    assert Document.equivalent?(@ics, remote)

    refute Document.equivalent?(
             @ics,
             String.replace(remote, "DESCRIPTION:Alarm", "DESCRIPTION:Changed")
           )

    refute Document.equivalent?(
             @card,
             String.replace(remote, "X-UNKNOWN:something", "X-UNKNOWN:changed")
           )

    refute Document.equivalent?("invalid", "invalid")
  end

  test "contact text edit retains groups, unknown parameters, photo and folding verbatim" do
    assert {:ok, raw} = Document.contact(@card, %{full_name: "New; name\nsecond"}, "one")
    assert raw =~ "FN:New\\; name\\nsecond\r\n"
    assert raw =~ "item1.EMAIL;TYPE=HOME;X-UNKNOWN=kept:a@example.org\r\nitem1.X-ABLabel:Private"
    assert raw =~ "PHOTO;ENCODING=b:abcdef"
    assert raw =~ "X-UNKNOWN:some\r\n thing"
    assert {:ok, %{full_name: "New; name\nsecond"}} = VCard.parse(raw)
  end

  test "name edits preserve additional structured parts" do
    assert {:ok, raw} = Document.contact(@card, %{given_name: "Other"}, "one")
    assert raw =~ "N:Family;Other;Middle;Dr;Jr"
  end

  test "adding an email retains original property parameters and Apple label" do
    assert {:ok, raw} =
             Document.contact(
               @card,
               %{
                 emails: [
                   %{"value" => "a@example.org", "label" => "HOME"},
                   %{"value" => "b@example.org", "label" => "WORK"}
                 ]
               },
               "one"
             )

    assert raw =~ "item1.EMAIL;TYPE=HOME;X-UNKNOWN=kept:a@example.org"
    assert raw =~ "item1.X-ABLabel:Private"
    assert raw =~ "EMAIL;TYPE=WORK:b@example.org"
  end

  test "deleting a property deletes its exclusive Apple label" do
    assert {:ok, raw} = Document.contact(@card, %{emails: []}, "one")
    refute raw =~ "item1.EMAIL"
    refute raw =~ "item1.X-ABLabel"
    assert raw =~ "PHOTO;ENCODING=b:abcdef"
  end

  test "new contact folds UTF8 by octets and roundtrips escaped values" do
    name = String.duplicate("联系人", 30)

    assert {:ok, raw} =
             Document.contact(
               nil,
               %{full_name: name, emails: [%{"value" => "a@example.org"}]},
               "stable"
             )

    assert String.valid?(raw)
    assert Enum.all?(String.split(raw, "\r\n"), &(byte_size(&1) <= 75))
    assert {:ok, %{uid: "stable", full_name: ^name}} = VCard.parse(raw)
  end

  test "editing master preserves exception, sibling, timezone and nested alarm" do
    assert {:ok, raw} =
             Document.event(
               @ics,
               %{summary: "New title", description: "Description"},
               "event",
               ""
             )

    assert raw =~ "SUMMARY:New title"
    assert raw =~ "DESCRIPTION:Alarm"
    assert raw =~ "SUMMARY:Exception"
    assert raw =~ "SUMMARY:Sibling"
    assert raw =~ "X-TIMEZONE:keep"
    assert {:ok, events} = ICalendar.parse(raw)
    assert length(events) == 3
  end

  test "removing exception preserves master while series deletion preserves sibling" do
    assert {:ok, raw} = Document.delete_event(@ics, "event", "20261011T100000")
    refute raw =~ "RECURRENCE-ID"
    assert raw =~ "RRULE:FREQ=DAILY"
    assert {:ok, raw} = Document.delete_event(@ics, "event", :series)
    refute raw =~ "UID:event"
    assert raw =~ "UID:sibling"
    assert {:ok, :empty} = Document.delete_event(raw, "sibling", :series)
  end

  test "deleting the last event refuses deletion of unrelated calendar components" do
    {:ok, raw} = Document.delete_event(@ics, "event", :series)

    for component <- ["VTODO", "VJOURNAL", "X-CUSTOM"] do
      mixed =
        String.replace(
          raw,
          "END:VCALENDAR",
          "BEGIN:#{component}\r\nUID:other\r\nX-KEEP:yes\r\nEND:#{component}\r\nEND:VCALENDAR"
        )

      assert {:ok, [_]} = ICalendar.parse(mixed)

      assert {:error, :unsupported_calendar_components} =
               Document.delete_event(mixed, "sibling", :series)

      assert {:error, :unsupported_calendar_components} = Document.delete_calendar(mixed)
    end

    assert {:ok, :empty} = Document.delete_calendar(raw)
  end

  test "scheduling resources refuse editing and deletion while remaining readable" do
    raw =
      String.replace(
        @ics,
        "SUMMARY:Old",
        "SUMMARY:Old\r\nORGANIZER:mailto:owner@example.test\r\nATTENDEE:mailto:guest@example.test"
      )

    assert {:ok, _} = ICalendar.parse(raw)

    assert {:error, :scheduling_not_supported} =
             Document.event(raw, %{summary: "Change"}, "event", "")

    assert {:error, :scheduling_not_supported} = Document.delete_event(raw, "event", :series)
  end

  test "new local event has stable UID and timezone representation" do
    assert {:ok, raw} =
             Document.event(
               nil,
               %{summary: "Local", starts_at: "20261010", ends_at: "20261011", all_day: true},
               "stable",
               ""
             )

    assert raw =~ "DTSTART;VALUE=DATE:20261010"
    assert {:ok, [%{uid: "stable", all_day: true}]} = ICalendar.parse(raw)
  end

  test "invalid target identity is rejected and equivalent folding accepted" do
    assert {:error, :identity_changed} = Document.contact(@card, %{}, "another")
    assert Document.equivalent?(@card, String.replace(@card, "some\r\n thing", "something"))

    refute Document.equivalent?(
             @card,
             String.replace(@card, "PHOTO;ENCODING=b:abcdef", "PHOTO;ENCODING=b:other")
           )
  end

  test "editing a selected email preserves its unknown parameters and group" do
    assert {:ok, card} = VCard.parse(@card)
    [email] = card.emails

    assert {:ok, raw} =
             Document.contact(
               @card,
               %{emails: [Map.put(email, "value", "updated@example.org")]},
               "one"
             )

    assert raw =~ "item1.EMAIL;TYPE=HOME;X-UNKNOWN=kept:updated@example.org"
    assert raw =~ "item1.X-ABLabel:Private"
  end

  test "case-insensitive grouped property names retain parameters when edited" do
    source = String.replace(@card, "item1.EMAIL", "item1.email")
    {:ok, %{emails: [email]}} = VCard.parse(source)

    assert {:ok, raw} =
             Document.contact(
               source,
               %{emails: [Map.put(email, "value", "changed@example.org")]},
               "one"
             )

    assert raw =~ "item1.email;TYPE=HOME;X-UNKNOWN=kept:changed@example.org"
  end

  test "event text and time edits retain unrelated property parameters" do
    ics =
      String.replace(@ics, "SUMMARY:Old", "SUMMARY;LANGUAGE=fr;X-KEEP=yes:Old")
      |> String.replace(
        "DTSTART;TZID=Europe/Paris:20261010T100000",
        "DTSTART;TZID=Europe/Paris;X-TIME=yes:20261010T100000"
      )

    assert {:ok, raw} =
             Document.event(ics, %{summary: "New", starts_at: "20261010T120000"}, "event", "")

    assert raw =~ "SUMMARY;LANGUAGE=fr;X-KEEP=yes:New"
    assert raw =~ "DTSTART;TZID=Europe/Paris;X-TIME=yes:20261010T120000"
  end
end

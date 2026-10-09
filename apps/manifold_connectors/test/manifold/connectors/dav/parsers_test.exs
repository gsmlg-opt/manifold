defmodule Manifold.Connectors.DAV.ParsersTest do
  use ExUnit.Case, async: true
  alias Manifold.Connectors.DAV.{XML, VCard, ICalendar, URL}

  test "DAV namespace URIs, successful properties and deletion status survive prefixes" do
    xml = """
    <x:multistatus xmlns:x="DAV:" xmlns:c="urn:ietf:params:xml:ns:carddav">
      <x:response><x:href>/book/one.vcf</x:href><x:propstat><x:prop>
      <x:getetag>&quot;1&quot;</x:getetag><x:resourcetype><c:addressbook/></x:resourcetype>
      </x:prop><x:status>HTTP/1.1 200 OK</x:status></x:propstat></x:response>
      <x:response><x:href>/book/deleted.vcf</x:href><x:status>HTTP/1.1 404 Not Found</x:status></x:response>
      <x:sync-token>urn:token:2</x:sync-token>
    </x:multistatus>
    """

    assert {:ok, %{responses: [first, deleted], sync_token: "urn:token:2"}} = XML.parse(xml)
    assert first.href == "/book/one.vcf"
    assert XML.text(first.props[{"DAV:", "getetag"}]) == ~s("1")
    assert deleted.status == 404

    assert {:error, _} =
             XML.parse("<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><x/>")

    assert {:error, _} = XML.parse("<multistatus xmlns='DAV:'><response>")
  end

  test "vCards unfold UTF8, preserve escaped structured and multiple values" do
    raw =
      "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:one\r\nFN:Ada\r\n  Lovelace\r\nN:Lovelace;Ada;;;\r\nEMAIL;TYPE=HOME:ada@example.test\r\nEMAIL;TYPE=WORK:work@example.test\r\nTEL;TYPE=CELL:+123\r\nADR;TYPE=HOME:;;One\\;Two Street;London;;;UK\r\nORG:Analytical Engine\r\nNOTE:Hello\\nworld\\, again\r\nEND:VCARD\r\n"

    assert {:ok, card} = VCard.parse(raw)
    assert card.full_name == "Ada Lovelace"
    assert card.given_name == "Ada"
    assert length(card.emails) == 2
    assert hd(card.addresses)["street"] == "One;Two Street"
    assert card.notes == "Hello\nworld, again"
    assert card.raw == raw
    assert {:error, _} = VCard.parse("BEGIN:VCARD\nUID:x\nEND:VCARD")
  end

  test "calendar all-day, timezone and recurrence exception remain distinct" do
    raw = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:series
    DTSTART;VALUE=DATE:20261010
    DTEND;VALUE=DATE:20261011
    SUMMARY:All day
    RRULE:FREQ=WEEKLY;COUNT=4
    EXDATE;VALUE=DATE:20261017
    END:VEVENT
    BEGIN:VEVENT
    UID:series
    RECURRENCE-ID;VALUE=DATE:20261024
    DTSTART;TZID=Asia/Shanghai:20261024T103000
    DTEND;TZID=Asia/Shanghai:20261024T113000
    SUMMARY:Moved\\, event
    END:VEVENT
    END:VCALENDAR
    """

    assert {:ok, [master, exception]} = ICalendar.parse(raw)
    assert master.all_day
    assert master.starts_at == "20261010"
    assert master.recurrence_rules == ["FREQ=WEEKLY;COUNT=4"]
    assert master.excluded_dates == ["20261017"]
    assert exception.recurrence_id == "20261024"
    assert exception.timezone == "Asia/Shanghai"
    assert exception.summary == "Moved, event"
    assert {:error, _} = ICalendar.parse("BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:x\nEND:VCALENDAR")
  end

  test "unsupported calendars, duplicate event identities and malformed card boundaries fail closed" do
    unsupported =
      "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VTODO\nUID:task\nEND:VTODO\nEND:VCALENDAR\n"

    assert {:error, _} = ICalendar.parse(unsupported)
    event = "BEGIN:VEVENT\nUID:same\nDTSTART:20261010\nEND:VEVENT\n"

    assert {:error, _} =
             ICalendar.parse(
               "BEGIN:VCALENDAR\nVERSION:2.0\n" <> event <> event <> "END:VCALENDAR\n"
             )

    assert {:error, _} =
             ICalendar.parse("BEGIN:VCALENDAR\nEND:VCALENDAR\nNOTE:outside\nEND:VCALENDAR")

    assert {:error, _} =
             VCard.parse(
               "BEGIN:VCARD\nVERSION:3.0\nUID:ada\nFN:Ada\nEND:VCARD\nNOTE:outside\nEND:VCARD"
             )
  end

  test "invalid calendar dates and incomplete nested components are rejected" do
    for date <- ["20260230", "20261010T256000Z", "20261301"] do
      raw =
        "BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nUID:bad\nDTSTART:" <>
          date <> "\nEND:VEVENT\nEND:VCALENDAR\n"

      assert {:error, _} = ICalendar.parse(raw)
    end
  end

  test "every discovered URL must be an explicit verified Apple DAV destination" do
    assert {:ok, "https://p42-contacts.icloud.com/book/"} =
             URL.resolve("https://contacts.icloud.com/", "https://p42-contacts.icloud.com/book/")

    for url <- [
          "https://contacts.icloud.com.evil.test/x",
          "https://evilicloud.com/x",
          "http://contacts.icloud.com/x",
          "https://user:pass@contacts.icloud.com/x",
          "https://contacts.icloud.com:444/x",
          "https://127.0.0.1/x",
          "https://contacts.icloud.com/x#fragment"
        ] do
      assert {:error, :untrusted_url} = URL.validate(url)
    end
  end
end

defmodule Manifold.Connectors.CalendarSync.ICloudTest do
  use ExUnit.Case, async: true
  alias Manifold.Connectors.CalendarSync.ICloud

  defp raw(summary \\ "Meeting") do
    "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nX-PROVIDER:keep\r\nBEGIN:VEVENT\r\nUID:uid\r\nDTSTART:20261019T090000Z\r\nDTEND:20261019T100000Z\r\nSUMMARY:#{summary}\r\nX-EVENT:keep\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"
  end

  test "decode keeps complete resource and scopes source series by resource and UID" do
    snapshot = %{id: "https://caldav.icloud.com/calendar/one.ics", raw: raw(), etag: "\"v1\""}

    assert {:ok,
            [%{key: "uid" <> <<31>>, projection: p, metadata: %{uid: "uid", series_key: key}}]} =
             ICloud.decode(snapshot, [])

    assert p["starts_at"] == "20261019T090000Z"
    assert key == snapshot.id <> <<31>> <> "uid"
  end

  test "full resource update preserves provider properties" do
    p = %{
      "summary" => "Edited",
      "starts_at" => "20261019T090000Z",
      "ends_at" => "20261019T100000Z",
      "all_day" => false,
      "timezone" => "Etc/UTC",
      "recurrence_id" => "",
      "recurrence_rules" => [],
      "recurrence_dates" => [],
      "excluded_dates" => [],
      "deleted" => false
    }

    assert {:ok, updated} =
             ICloud.encode(%{base_raw: raw()}, [%{event: %{uid: "uid"}, projection: p}], [])

    assert updated =~ "SUMMARY:Edited"
    assert updated =~ "X-PROVIDER:keep"
    assert updated =~ "X-EVENT:keep"
  end

  test "reserved resource destination is fixed within validated Apple collection" do
    assert {:ok, "https://caldav.icloud.com/calendar/reserved.ics"} =
             ICloud.destination(%{remote_calendar_id: "https://caldav.icloud.com/calendar/"}, %{
               href: nil,
               remote_resource_id: "reserved"
             })

    assert {:error, :untrusted_url} =
             ICloud.destination(%{remote_calendar_id: "https://attacker.test/calendar/"}, %{
               href: nil,
               remote_resource_id: "reserved"
             })
  end

  test "conditional update maps conflict and uncertain transport without replay" do
    owner = self()

    transport = fn method, url, headers, body ->
      send(owner, {:write, method, url, headers, body})
      {:ok, %{status: 412, headers: %{}, body: ""}}
    end

    attempt = %{
      operation: "upsert",
      destination: "https://caldav.icloud.com/calendar/one.ics",
      payload: raw(),
      precondition: %{"if_match" => "\"v1\""}
    }

    opts = [
      credentials: %{apple_id: "dummy@example.test", app_password: "dummy-password"},
      transport: transport
    ]

    assert {:error, :conflict} = ICloud.execute(attempt, %{id: "connection"}, opts)
    assert_receive {:write, :put, _, headers, _}
    assert {"if-match", "\"v1\""} in headers

    assert {:error, :unknown} =
             ICloud.execute(
               attempt,
               %{id: "connection"},
               Keyword.put(opts, :transport, fn _, _, _, _ -> {:error, :timeout} end)
             )
  end

  test "complete deletion does not remove unrepresented VTODO data or scheduling content" do
    unsafe =
      String.replace(
        raw(),
        "END:VCALENDAR",
        "BEGIN:VTODO\r\nUID:todo\r\nEND:VTODO\r\nEND:VCALENDAR"
      )

    assert {:error, _} = ICloud.validate_delete(%{base_raw: unsafe}, [], [])
    assert :ok = ICloud.validate_delete(%{base_raw: raw()}, [], [])
  end

  test "missing write precondition is rejected before network admission" do
    attempt = %{
      operation: "upsert",
      destination: "https://caldav.icloud.com/calendar/one.ics",
      payload: raw(),
      precondition: %{}
    }

    assert {:error, :missing_precondition} =
             ICloud.execute(attempt, %{id: "c"},
               credentials: %{apple_id: "dummy", app_password: "dummy"},
               transport: fn _, _, _, _ -> flunk("unexpected write") end
             )
  end

  test "display alarms project canonical reminders without deleting unknown alarms" do
    calendar =
      String.replace(
        raw(),
        "END:VEVENT",
        "BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT15M\r\nDESCRIPTION:Reminder\r\nEND:VALARM\r\nEND:VEVENT"
      )

    assert {:ok, [%{projection: p, fields: fields}]} =
             ICloud.decode(%{id: "resource", raw: calendar}, [])

    assert p["reminders"] == [%{"method" => "popup", "minutes" => 15}]
    assert "reminders" in fields
    unknown = String.replace(calendar, "ACTION:DISPLAY", "ACTION:AUDIO")

    assert {:ok, [%{fields: fields, metadata: metadata}]} =
             ICloud.decode(%{id: "resource", raw: unknown}, [])

    refute "reminders" in fields
    assert metadata.capability_limits == ["unsupported_alarms"]
  end
end

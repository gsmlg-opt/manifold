defmodule Manifold.Connectors.CalendarSync.GoogleTest do
  use ExUnit.Case, async: true
  alias Manifold.Connectors.CalendarSync.Google

  defp google_event(attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "remote",
        "iCalUID" => "uid",
        "etag" => "\"v1\"",
        "summary" => "Meeting",
        "start" => %{"dateTime" => "2026-10-19T09:00:00-04:00", "timeZone" => "America/New_York"},
        "end" => %{"dateTime" => "2026-10-19T10:00:00-04:00", "timeZone" => "America/New_York"}
      },
      attrs
    )
  end

  test "decode preserves TZID recurrence, exclusion parameters and unknown raw fields" do
    raw =
      google_event(%{
        "recurrence" => ["RRULE:FREQ=DAILY", "EXDATE;TZID=America/New_York:20261020T090000"],
        "unknown" => %{"keep" => true}
      })

    assert {:ok, [%{key: "uid" <> <<31>>, projection: p, metadata: %{series_key: "remote"}}]} =
             Google.decode(%{raw: Jason.encode!(raw)}, [])

    assert p["starts_at"] == "20261019T090000"
    assert p["timezone"] == "America/New_York"
    assert p["recurrence_rules"] == ["FREQ=DAILY"]
    assert p["excluded_dates"] == ["EXDATE;TZID=America/New_York:20261020T090000"]
  end

  test "moved instance key retains original slot and source-proven parent identity" do
    raw =
      google_event(%{
        "recurringEventId" => "master",
        "originalStartTime" => %{
          "dateTime" => "2026-10-18T09:00:00-04:00",
          "timeZone" => "America/New_York"
        }
      })

    assert {:ok,
            [
              %{
                key: "uid" <> <<31>> <> "20261018T090000",
                projection: p,
                metadata: %{series_key: "master"}
              }
            ]} = Google.decode(%{raw: Jason.encode!(raw)}, [])

    assert p["recurrence_id"] == "20261018T090000"
    assert p["starts_at"] == "20261019T090000"
  end

  test "all-day end stays exclusive and exported canonical UID marker is stable" do
    raw =
      google_event(%{
        "start" => %{"date" => "2026-10-19"},
        "end" => %{"date" => "2026-10-20"},
        "extendedProperties" => %{"private" => %{"manifold_uid" => "local-uid"}}
      })

    assert {:ok, [%{key: "local-uid" <> <<31>>, projection: p}]} =
             Google.decode(%{raw: Jason.encode!(raw)}, [])

    assert p["starts_at"] == "20261019"
    assert p["ends_at"] == "20261020"
    assert p["all_day"]
  end

  test "full pagination completes before returning next sync token" do
    base =
      server([
        {200, %{"items" => [google_event()], "nextPageToken" => "second"}},
        {200,
         %{"items" => [google_event(%{"id" => "remote-two"})], "nextSyncToken" => "checkpoint"}}
      ])

    assert {:ok,
            %{
              complete: true,
              mode: :full,
              checkpoint: %{"sync_token" => "checkpoint"},
              resources: [_, _]
            }} =
             Google.fetch_changes(
               %{connection_id: "connection", remote_calendar_id: "calendar@example.test"},
               %{},
               opts(base)
             )

    assert_receive {:request, first, _}
    assert first =~ "showDeleted=true"
    assert_receive {:request, second, _}
    assert second =~ "pageToken=second"
  end

  test "failed later page never returns a partial snapshot or checkpoint" do
    base =
      server([{200, %{"items" => [google_event()], "nextPageToken" => "second"}}, {503, %{}}])

    assert {:error, _} =
             Google.fetch_changes(
               %{connection_id: "c", remote_calendar_id: "calendar"},
               %{},
               opts(base)
             )
  end

  test "expired sync token restarts a complete full snapshot" do
    base = server([{410, %{}}, {200, %{"items" => [], "nextSyncToken" => "fresh"}}])

    assert {:ok, %{mode: :full, checkpoint: %{"sync_token" => "fresh"}, resources: []}} =
             Google.fetch_changes(
               %{connection_id: "c", remote_calendar_id: "calendar"},
               %{"sync_token" => "expired"},
               opts(base)
             )

    assert_receive {:request, first, _}
    assert first =~ "syncToken=expired"
    assert_receive {:request, second, _}
    refute second =~ "syncToken="
  end

  test "conditional update uses immutable destination and emits no transport retry" do
    base = server([{412, %{}}])

    attempt = %{
      operation: "upsert",
      destination: base <> "/calendars/calendar/events/remote",
      payload: "{}",
      precondition: %{"if_match" => "\"v1\""}
    }

    assert {:error, :conflict} = Google.execute(attempt, %{id: "c"}, opts(base))
    assert_receive {:request, request, "{}"}
    assert request =~ "PATCH /calendars/calendar/events/remote"
    assert request =~ "if-match: \"v1\""
  end

  test "write response loss remains unknown and is not replayed" do
    base = server([:close])

    attempt = %{
      operation: "upsert",
      destination: base <> "/calendars/calendar/events/reserved",
      payload: "{\"id\":\"reserved\"}",
      precondition: %{"if_none_match" => "*"}
    }

    assert {:error, :unknown} = Google.execute(attempt, %{id: "c"}, opts(base))
    assert_receive {:request, request, _}
    assert request =~ "POST /calendars/calendar/events"
  end

  test "PATCH serializes covered fields while preserving unknown provider properties" do
    projection = %{
      "summary" => "Edited",
      "description" => nil,
      "location" => nil,
      "starts_at" => "20261019T090000Z",
      "ends_at" => "20261019T100000Z",
      "timezone" => "Etc/UTC",
      "all_day" => false,
      "recurrence_rules" => [],
      "recurrence_dates" => [],
      "excluded_dates" => [],
      "recurrence_id" => ""
    }

    resource = %{
      remote_resource_id: "reserved",
      base_raw: Jason.encode!(google_event(%{"unknown" => "preserved"}))
    }

    assert {:ok, payload} =
             Google.encode(resource, [%{event: %{uid: "local-uid"}, projection: projection}], [])

    assert {:ok, body} = Jason.decode(payload)
    assert body["summary"] == "Edited"
    refute Map.has_key?(body, "unknown")
    assert body["extendedProperties"]["private"]["manifold_uid"] == "local-uid"
  end

  test "exact original slot preflight returns remote instance and target baseline before write" do
    parent = google_event(%{"id" => "parent", "recurrence" => ["RRULE:FREQ=DAILY"]})
    {:ok, [%{projection: baseline}]} = Google.decode(%{raw: Jason.encode!(parent)}, [])

    instance =
      google_event(%{
        "id" => "actual-instance",
        "recurringEventId" => "parent",
        "originalStartTime" => %{
          "dateTime" => "2026-10-20T09:00:00-04:00",
          "timeZone" => "America/New_York"
        },
        "start" => %{"dateTime" => "2026-10-20T09:00:00-04:00", "timeZone" => "America/New_York"},
        "end" => %{"dateTime" => "2026-10-20T10:00:00-04:00", "timeZone" => "America/New_York"}
      })

    base = server([{200, %{"items" => [instance]}}])

    resource = %{
      base_raw: nil,
      href: nil,
      remote_resource_id: "reserved",
      provider_metadata: %{
        "master_remote_id" => "parent",
        "original_slot" => "20261020T090000",
        "master_base_projection" => baseline,
        "master_uid" => "uid"
      }
    }

    assert {:ok,
            %{id: "actual-instance", etag: "\"v1\"", metadata: %{original_projection: expected}}} =
             Google.resolve_target(
               %{remote_calendar_id: "calendar", connection_id: "c"},
               resource,
               opts(base)
             )

    assert expected["starts_at"] == "20261020T090000"
    assert expected["ends_at"] == "20261020T100000"
    assert expected["recurrence_id"] == "20261020T090000"
    assert expected["recurrence_rules"] == []
    assert_receive {:request, request, _}
    assert request =~ "originalStart="
    assert request =~ "/events/parent/instances"
  end

  test "new detached instance with no mapped master is explicitly limited" do
    resource = %{
      base_raw: nil,
      href: nil,
      provider_metadata: %{"original_slot" => "20261020T090000"}
    }

    assert {:error, :unmapped_series_master} =
             Google.resolve_target(%{remote_calendar_id: "calendar"}, resource, [])
  end

  test "reliably canceled event without ETag is a deletion, not an incomplete batch" do
    base =
      server([
        {200,
         %{"items" => [%{"id" => "deleted", "status" => "cancelled"}], "nextSyncToken" => "next"}}
      ])

    assert {:ok, %{resources: [%{id: "deleted", presence: :deleted, etag: nil}]}} =
             Google.fetch_changes(
               %{connection_id: "c", remote_calendar_id: "calendar"},
               %{},
               opts(base)
             )
  end

  test "sparse canceled instance is hydrated from its parent and preserves the deleted slot" do
    cancelled = %{
      "id" => "instance",
      "recurringEventId" => "parent",
      "status" => "cancelled",
      "originalStartTime" => %{"dateTime" => "2026-10-20T09:00:00-04:00"}
    }

    base =
      server([
        {200, %{"items" => [cancelled], "nextSyncToken" => "next"}},
        {200, google_event(%{"id" => "parent"})}
      ])

    assert {:ok, %{resources: [snapshot]}} =
             Google.fetch_changes(
               %{connection_id: "c", remote_calendar_id: "calendar"},
               %{},
               opts(base)
             )

    assert {:ok, [%{projection: p, metadata: %{series_key: "parent"}}]} =
             Google.decode(snapshot, [])

    assert p["deleted"]
    assert p["recurrence_id"] == "20261020T090000"
  end

  test "repeated pagination token fails the whole snapshot" do
    base =
      server([
        {200, %{"items" => [], "nextPageToken" => "same"}},
        {200, %{"items" => [], "nextPageToken" => "same"}}
      ])

    assert {:error, :repeated_page_token} =
             Google.fetch_changes(
               %{connection_id: "c", remote_calendar_id: "calendar"},
               %{},
               opts(base)
             )
  end

  test "unsupported recurrence properties are explicit" do
    raw = google_event(%{"recurrence" => ["EXRULE:FREQ=WEEKLY;BYDAY=MO"]})

    assert {:error, :unsupported_recurrence_property} =
             Google.decode(%{raw: Jason.encode!(raw)}, [])
  end

  test "detached instance patch omits series recurrence and guards scheduling deletes" do
    {:ok, [%{projection: p}]} = Google.decode(%{raw: Jason.encode!(google_event())}, [])
    p = Map.put(p, "recurrence_id", "20261018T090000")

    assert {:ok, payload} =
             Google.encode(
               %{remote_resource_id: "instance", base_raw: Jason.encode!(google_event())},
               [%{event: %{uid: "uid"}, projection: p}],
               []
             )

    refute Map.has_key?(Jason.decode!(payload), "recurrence")

    assert {:error, :scheduling_not_supported} =
             Google.validate_delete(
               %{
                 base_raw:
                   Jason.encode!(
                     google_event(%{"attendees" => [%{"email" => "guest@example.test"}]})
                   )
               },
               [],
               []
             )
  end

  test "explicit reminder overrides are canonical and round trip without inherited defaults" do
    raw =
      google_event(%{
        "reminders" => %{
          "useDefault" => false,
          "overrides" => [%{"method" => "popup", "minutes" => 15}]
        }
      })

    assert {:ok, [%{projection: p, fields: fields}]} =
             Google.decode(%{raw: Jason.encode!(raw)}, [])

    assert p["reminders"] == [%{"method" => "popup", "minutes" => 15}]
    assert "reminders" in fields

    assert {:ok, payload} =
             Google.encode(
               %{remote_resource_id: "remote", base_raw: Jason.encode!(raw)},
               [%{event: %{uid: "uid"}, projection: p}],
               []
             )

    assert Jason.decode!(payload)["reminders"] == %{
             "useDefault" => false,
             "overrides" => [%{"method" => "popup", "minutes" => 15}]
           }
  end

  test "inherited defaults retain unknown reminder semantics during unrelated edits" do
    raw = google_event(%{"reminders" => %{"useDefault" => true}})

    assert {:ok, [%{projection: p, fields: fields, metadata: metadata}]} =
             Google.decode(%{raw: Jason.encode!(raw)}, [])

    refute "reminders" in fields
    assert metadata.capability_limits == ["inherited_default_reminders"]

    assert {:ok, payload} =
             Google.encode(
               %{remote_resource_id: "remote", base_raw: Jason.encode!(raw)},
               [%{event: %{uid: "uid"}, projection: Map.put(p, "summary", "Edited")}],
               []
             )

    refute Map.has_key?(Jason.decode!(payload), "reminders")
  end

  defp opts(base),
    do: [base_url: base, connection: %{id: "c"}, credentials: %{access_token: "dummy-token"}]

  defp server(responses) do
    owner = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      spawn(fn ->
        Enum.each(responses, fn response ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          {request, body} = read_request(socket, "")
          send(owner, {:request, request, body})

          if response != :close do
            {status, json} = response
            body = Jason.encode!(json)

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 #{status} response\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
                  body
              )
          end

          :gen_tcp.close(socket)
        end)

        :gen_tcp.close(listener)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp read_request(socket, bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        size =
          case Regex.run(~r/content-length: (\d+)/i, headers) do
            [_, length] -> String.to_integer(length)
            _ -> 0
          end

        if byte_size(body) >= size, do: {headers, body}, else: receive_more(socket, bytes)

      _ ->
        receive_more(socket, bytes)
    end
  end

  defp receive_more(socket, bytes) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
    read_request(socket, bytes <> chunk)
  end
end

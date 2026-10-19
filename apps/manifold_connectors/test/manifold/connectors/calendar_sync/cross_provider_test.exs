defmodule Manifold.Connectors.CalendarSync.CrossProviderTest do
  use Manifold.DataCase, async: true

  alias Manifold.Calendars
  alias Manifold.Connectors.{CalendarSync, DAV.Transport}

  alias Manifold.Data.Schema.{
    CalendarBinding,
    CalendarConnection,
    CalendarEvent,
    CalendarEventBinding,
    CalendarSyncAttempt
  }

  alias Manifold.Repo
  import Ecto.Query

  setup do
    {:ok, calendar} = Calendars.create_calendar(%{name: "One local calendar"})
    google = binding(calendar, "google", "calendar")
    apple = binding(calendar, "icloud", "https://caldav.icloud.com/apple/calendar/")

    state =
      start_supervised!(
        {Agent,
         fn ->
           %{google: %{}, apple: %{}, apple_deleted: [], revision: 0, writes: [], drop_next: nil}
         end}
      )

    base = peer(state)

    google_opts = [
      google_base_url: base <> "/google",
      credentials: %{access_token: "dummy-token"}
    ]

    apple_opts = [
      credentials: %{apple_id: "dummy@example.test", app_password: "dummy-password"},
      transport: fn method, url, headers, body ->
        Transport.request(method, base <> URI.parse(url).path, headers, body)
      end
    ]

    %{
      calendar: calendar,
      google: google,
      apple: apple,
      state: state,
      google_opts: google_opts,
      apple_opts: apple_opts
    }
  end

  test "one canonical identity converges to both providers and echoes survive durable reloads",
       c do
    {:ok, event} = create(c.calendar)
    run(c.google, c.google_opts)
    run(c.apple, c.apple_opts)
    assert_remote_counts(c.state, 1, 1)
    assert_ids_and_acknowledgements(event, c)
    writes = writes(c.state)
    revision = Repo.get!(CalendarEvent, event.id).local_revision

    for _ <- 1..3 do
      run(c.google, c.google_opts)
      run(c.apple, c.apple_opts)
    end

    assert writes(c.state) == writes
    assert Repo.get!(CalendarEvent, event.id).local_revision == revision
    assert Repo.aggregate(CalendarEvent, :count) == 1
    {:ok, edited} = Calendars.update_event(event.id, %{summary: "Changed locally"})
    run(c.google, c.google_opts)
    run(c.apple, c.apple_opts)
    assert_ids_and_acknowledgements(edited, c)
    {:ok, _} = Calendars.delete_event(event.id)
    run(c.google, c.google_opts)
    run(c.apple, c.apple_opts)
    assert_remote_counts(c.state, 0, 0)
    assert Repo.get!(CalendarEvent, event.id).deleted_at
  end

  test "Google inbound create and Apple inbound edit/delete propagate through one local identity",
       c do
    remote = %{
      "id" => "google-created",
      "iCalUID" => "google-uid",
      "etag" => "\"g1\"",
      "summary" => "Google created",
      "start" => %{"dateTime" => "2026-10-19T09:00:00Z"},
      "end" => %{"dateTime" => "2026-10-19T10:00:00Z"}
    }

    Agent.update(c.state, &put_in(&1, [:google, "google-created"], remote))
    run(c.google, c.google_opts)
    assert [local] = Repo.all(CalendarEvent)
    assert local.summary == "Google created"
    run(c.apple, c.apple_opts)
    assert_remote_counts(c.state, 1, 1)

    Agent.update(c.state, fn state ->
      [{path, resource}] = Map.to_list(state.apple)

      updated = %{
        resource
        | raw: String.replace(resource.raw, "SUMMARY:Google created", "SUMMARY:Apple edited"),
          etag: "\"apple-edit\""
      }

      %{state | apple: Map.put(state.apple, path, updated), revision: state.revision + 1}
    end)

    run(c.apple, c.apple_opts)
    assert Repo.get!(CalendarEvent, local.id).summary == "Apple edited"
    run(c.google, c.google_opts)
    assert Agent.get(c.state, & &1.google["google-created"]["summary"]) == "Apple edited"
    assert Repo.aggregate(CalendarEvent, :count) == 1

    Agent.update(c.state, fn state ->
      [path] = Map.keys(state.apple)
      %{state | apple: %{}, apple_deleted: [path], revision: state.revision + 1}
    end)

    run(c.apple, c.apple_opts)
    run(c.google, c.google_opts)
    assert Repo.get!(CalendarEvent, local.id).deleted_at
    assert_remote_counts(c.state, 0, 0)
  end

  test "unknown create reconciles without replay while the other target and newer revision advance",
       c do
    {:ok, event} = create(c.calendar)
    Agent.update(c.state, &%{&1 | drop_next: :google})
    first_worker = run_fresh_worker(c.google, c.google_opts)
    assert [%{state: "uncertain"}] = Repo.all(CalendarSyncAttempt)
    run(c.apple, c.apple_opts)
    {:ok, _} = CalendarSync.pause(c.apple.id)

    {:ok, newer} =
      Calendars.update_event(event.id, %{summary: "Revision after unknown submission"})

    apple_writes = writes(c.state) |> Enum.filter(&(elem(&1, 0) == :apple))
    restarted_worker = run_fresh_worker(c.google, c.google_opts)
    assert first_worker != restarted_worker
    assert Repo.get!(CalendarEvent, event.id).local_revision == newer.local_revision

    assert Agent.get(c.state, fn state ->
             Enum.count(state.writes, &match?({:google, "POST", _}, &1))
           end) == 1

    assert Agent.get(c.state, fn state ->
             Enum.count(state.writes, &match?({:google, "PATCH", _}, &1))
           end) == 1

    assert writes(c.state) |> Enum.filter(&(elem(&1, 0) == :apple)) == apple_writes
    assert {:ok, _} = CalendarSync.resume(c.apple.id)
    run(c.apple, c.apple_opts)
    assert_ids_and_acknowledgements(newer, c)
  end

  test "a worker killed after remote acceptance recovers its dispatched attempt without another create",
       c do
    {:ok, event} = create(c.calendar)
    parent = self()
    transport = Keyword.fetch!(c.apple_opts, :transport)

    paused_transport = fn method, url, headers, body ->
      response = transport.(method, url, headers, body)

      if method in [:put, "PUT"] do
        send(parent, {:remote_accepted, self()})

        receive do
          :release_response -> response
        end
      else
        response
      end
    end

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :run ->
            CalendarSync.run(
              c.apple.id,
              c.apple.generation,
              Keyword.put(c.apple_opts, :transport, paused_transport)
            )
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker)
    send(worker, :run)
    assert_receive {:remote_accepted, ^worker}, 5_000
    assert [%{state: "dispatched"}] = Repo.all(CalendarSyncAttempt)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 5_000
    # Deterministically cross the persisted takeover deadline after worker death.
    Repo.get!(CalendarBinding, c.apple.id)
    |> Ecto.Changeset.change(lease_expires_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    run_fresh_worker(c.apple, c.apple_opts)
    run(c.google, c.google_opts)
    assert_remote_counts(c.state, 1, 1)
    assert Enum.count(writes(c.state), &match?({:apple, "PUT", _}, &1)) == 1
    assert_ids_and_acknowledgements(event, c)
    assert Enum.all?(Repo.all(CalendarSyncAttempt), &(&1.state == "succeeded"))
  end

  test "Apple inbound create and Google inbound edit/delete preserve reminders and one identity",
       c do
    raw =
      "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:apple-created\r\n" <>
        "DTSTART:20261019T090000Z\r\nDTEND:20261019T100000Z\r\nSUMMARY:Apple created\r\n" <>
        "BEGIN:VALARM\r\nACTION:DISPLAY\r\nTRIGGER:-PT30M\r\nDESCRIPTION:Reminder\r\n" <>
        "END:VALARM\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

    Agent.update(c.state, fn state ->
      %{state | apple: %{"/apple/calendar/created.ics" => %{raw: raw, etag: "\"apple-1\""}}}
    end)

    run(c.apple, c.apple_opts)
    assert [local] = Repo.all(CalendarEvent)
    assert local.summary == "Apple created"
    assert local.reminders == [%{"method" => "popup", "minutes" => 30}]
    run(c.google, c.google_opts)
    assert_remote_counts(c.state, 1, 1)
    assert_ids_and_acknowledgements(local, c)

    Agent.update(c.state, fn state ->
      [{id, event}] = Map.to_list(state.google)
      assert event["reminders"] == %{"useDefault" => false, "overrides" => local.reminders}

      edited =
        event
        |> Map.put("summary", "Google edited")
        |> Map.put("reminders", %{
          "useDefault" => false,
          "overrides" => [%{"method" => "popup", "minutes" => 15}]
        })
        |> Map.put("etag", "\"google-edit\"")

      %{state | google: %{id => edited}, revision: state.revision + 1}
    end)

    run(c.google, c.google_opts)
    run(c.apple, c.apple_opts)
    updated = Repo.get!(CalendarEvent, local.id)
    assert updated.summary == "Google edited"
    assert updated.reminders == [%{"method" => "popup", "minutes" => 15}]
    assert Agent.get(c.state, & &1.apple["/apple/calendar/created.ics"].raw) =~ "TRIGGER:-PT15M"
    assert Repo.aggregate(CalendarEvent, :count) == 1
    assert_ids_and_acknowledgements(updated, c)

    Agent.update(c.state, fn state ->
      [{id, event}] = Map.to_list(state.google)
      deleted = event |> Map.put("status", "cancelled") |> Map.put("etag", "\"google-delete\"")
      %{state | google: %{id => deleted}, revision: state.revision + 1}
    end)

    run(c.google, c.google_opts)
    run(c.apple, c.apple_opts)
    assert Repo.get!(CalendarEvent, local.id).deleted_at
    assert_remote_counts(c.state, 0, 0)
  end

  test "moved and deleted occurrence retains a single slot across both real HTTP adapters", c do
    {:ok, master} = create(c.calendar, %{recurrence_rules: ["FREQ=DAILY;COUNT=3"]})
    run(c.google, c.google_opts)
    run(c.apple, c.apple_opts)

    assert {:ok, exception} =
             Calendars.update_occurrence(master.id, "20261020T090000Z", %{
               starts_at: "20261020T120000Z",
               ends_at: "20261020T130000Z",
               summary: "Moved"
             })

    run(c.google, c.google_opts)
    run(c.apple, c.apple_opts)
    assert Repo.get!(CalendarEvent, exception.id).recurrence_id == "20261020T090000Z"
    assert {:ok, _} = Calendars.delete_event(exception.id, scope: :occurrence)

    for _ <- 1..2 do
      run(c.google, c.google_opts)
      run(c.apple, c.apple_opts)
    end

    assert {:ok, occurrences} =
             Calendars.list_occurrences([c.calendar.id],
               from: ~D[2026-10-19],
               until: ~D[2026-10-22]
             )

    assert Enum.map(occurrences, & &1.recurrence_id) == ["20261019T090000Z", "20261021T090000Z"]
    assert Repo.aggregate(CalendarEvent, :count) == 2

    assert Agent.get(c.state, fn state ->
             Enum.count(state.writes, &match?({:google, "POST", _}, &1))
           end) == 1
  end

  defp create(calendar, attrs \\ %{}) do
    Calendars.create_event(
      Map.merge(
        %{
          calendar_id: calendar.id,
          summary: "Local",
          starts_at: "20261019T090000Z",
          ends_at: "20261019T100000Z",
          timezone: "Etc/UTC"
        },
        attrs
      )
    )
  end

  defp binding(calendar, provider, remote_id) do
    connection =
      Repo.insert!(
        Ecto.Changeset.change(%CalendarConnection{},
          provider: provider,
          status: "active",
          generation: 1,
          credential_context: "controlled-peer",
          encrypted_credentials: "unused"
        )
      )

    Repo.insert!(
      Ecto.Changeset.change(%CalendarBinding{},
        calendar_id: calendar.id,
        connection_id: connection.id,
        remote_calendar_id: remote_id,
        state: "active",
        generation: 1,
        direction: "bidirectional",
        capabilities: %{"write" => true},
        enrollment_manifest: %{"confirmed_at" => "2000-01-01T00:00:00Z"}
      )
    )
  end

  defp run(binding, opts),
    do:
      assert(
        {:ok, _} =
          CalendarSync.run(binding.id, Repo.get!(CalendarBinding, binding.id).generation, opts)
      )

  defp run_fresh_worker(binding, opts) do
    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        receive do
          :run ->
            send(
              parent,
              {self(),
               CalendarSync.run(
                 binding.id,
                 Repo.get!(CalendarBinding, binding.id).generation,
                 opts
               )}
            )
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), worker)
    send(worker, :run)
    assert_receive {^worker, {:ok, _}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    worker
  end

  defp writes(state), do: Agent.get(state, &Enum.reverse(&1.writes))

  defp assert_remote_counts(state, google, apple) do
    assert Agent.get(state, fn s ->
             Enum.count(s.google, fn {_, v} ->
               v["status"] != "cancelled" and v["_generated"] != true
             end)
           end) == google

    assert Agent.get(state, &map_size(&1.apple)) == apple
  end

  defp assert_ids_and_acknowledgements(event, c) do
    assert %{id: id} = Repo.get!(CalendarEvent, event.id)
    assert id == event.id
    assert bindings = Repo.all(from(b in CalendarEventBinding, where: b.event_id == ^id))

    assert MapSet.new(Enum.map(bindings, & &1.binding_id)) ==
             MapSet.new([c.google.id, c.apple.id])

    assert Enum.all?(bindings, &(&1.acknowledged_revision == event.local_revision))
  end

  defp peer(state) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    server = spawn(fn -> accept(listener, state) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp accept(listener, state) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {head, body} = read_request(socket, "")
        [request | headers] = String.split(head, "\r\n")
        [method, target, _] = String.split(request, " ")

        headers =
          Map.new(headers, fn line ->
            [name, value] = String.split(line, ":", parts: 2)
            {String.downcase(name), String.trim(value)}
          end)

        response =
          Agent.get_and_update(state, fn s ->
            {status, response_headers, response_body, updated} =
              route(method, URI.parse(target), headers, body, s)

            provider = if String.starts_with?(target, "/google/"), do: :google, else: :apple
            write? = method in ["POST", "PATCH", "PUT", "DELETE"]

            updated =
              if write?,
                do: %{updated | writes: [{provider, method, target} | updated.writes]},
                else: updated

            if write? and s.drop_next == provider,
              do: {:drop, %{updated | drop_next: nil}},
              else: {{status, response_headers, response_body}, updated}
          end)

        if response != :drop do
          {status, headers, body} = response

          headers =
            headers ++
              [{"content-length", Integer.to_string(byte_size(body))}, {"connection", "close"}]

          :gen_tcp.send(socket, [
            "HTTP/1.1 #{status} response\r\n",
            Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end),
            "\r\n",
            body
          ])
        end

        :gen_tcp.close(socket)
        accept(listener, state)

      {:error, :closed} ->
        :ok
    end
  end

  defp route(method, %{path: "/google/calendars/calendar/events"} = uri, _headers, body, state) do
    case method do
      "GET" ->
        items = state.google |> Map.values() |> Enum.reject(& &1["_generated"])
        json(200, %{"items" => items, "nextSyncToken" => "token-#{state.revision}"}, state)

      "POST" ->
        event = Jason.decode!(body)
        id = event["id"]

        if state.google[id] do
          json(409, %{}, state)
        else
          event =
            event |> Map.put("iCalUID", id <> "@controlled.test") |> Map.put("etag", etag(state))

          updated = %{
            state
            | google: Map.put(state.google, id, event),
              revision: state.revision + 1
          }

          json(200, event, updated)
        end

      _ ->
        json(400, %{query: uri.query}, state)
    end
  end

  defp route(
         method,
         %{path: "/google/calendars/calendar/events/" <> rest} = uri,
         headers,
         body,
         state
       ) do
    case String.split(rest, "/") do
      [master, "instances"] -> instances(master, uri, state)
      [id] -> google_resource(method, id, headers, body, state)
    end
  end

  defp route("PROPFIND", %{path: "/apple/calendar/"}, _headers, _body, state) do
    collection =
      "<d:response><d:href>/apple/calendar/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/><c:calendar/></d:resourcetype><d:sync-token>token-#{state.revision}</d:sync-token></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"

    xml(207, collection <> apple_entries(state), state)
  end

  defp route("REPORT", %{path: "/apple/calendar/"}, _headers, _body, state) do
    deleted =
      Enum.map_join(
        state.apple_deleted,
        &"<d:response><d:href>#{&1}</d:href><d:status>HTTP/1.1 404 Not Found</d:status></d:response>"
      )

    xml(
      207,
      "<d:sync-token>token-#{state.revision}</d:sync-token>" <> apple_entries(state) <> deleted,
      state
    )
  end

  defp route(method, %{path: "/apple/calendar/" <> _ = path}, headers, body, state) do
    existing = state.apple[path]

    cond do
      method == "GET" and existing ->
        {200, [{"etag", existing.etag}], existing.raw, state}

      method == "GET" ->
        {404, [], "", state}

      (method == "PUT" and headers["if-match"]) &&
          (is_nil(existing) || existing.etag != headers["if-match"]) ->
        {412, [], "", state}

      method == "PUT" and headers["if-none-match"] == "*" and existing ->
        {412, [], "", state}

      method == "PUT" ->
        tag = etag(state)

        updated = %{
          state
          | apple: Map.put(state.apple, path, %{raw: body, etag: tag}),
            apple_deleted: List.delete(state.apple_deleted, path),
            revision: state.revision + 1
        }

        {201, [{"etag", tag}], "", updated}

      (method == "DELETE" and existing) && headers["if-match"] != existing.etag ->
        {412, [], "", state}

      method == "DELETE" ->
        {204, [], "",
         %{
           state
           | apple: Map.delete(state.apple, path),
             apple_deleted: Enum.uniq([path | state.apple_deleted]),
             revision: state.revision + 1
         }}

      true ->
        {400, [], "", state}
    end
  end

  defp google_resource(method, id, headers, body, state) do
    existing = state.google[id]

    cond do
      method == "GET" and existing ->
        json(200, existing, state)

      method == "GET" ->
        json(404, %{}, state)

      is_nil(existing) ->
        json(404, %{}, state)

      headers["if-match"] != existing["etag"] ->
        json(412, %{}, state)

      method == "PATCH" ->
        updated =
          existing
          |> Map.merge(Jason.decode!(body))
          |> Map.delete("_generated")
          |> Map.put("etag", etag(state))

        json(200, updated, %{
          state
          | google: Map.put(state.google, id, updated),
            revision: state.revision + 1
        })

      method == "DELETE" ->
        deleted =
          existing
          |> Map.put("status", "cancelled")
          |> Map.put("etag", etag(state))
          |> Map.delete("_generated")

        {204, [], "",
         %{state | google: Map.put(state.google, id, deleted), revision: state.revision + 1}}
    end
  end

  defp instances(master_id, uri, state) do
    master = state.google[master_id]
    original = URI.decode_query(uri.query)["originalStart"]
    {:ok, start, _} = DateTime.from_iso8601(original)
    {:ok, master_start, _} = DateTime.from_iso8601(master["start"]["dateTime"])
    {:ok, master_end, _} = DateTime.from_iso8601(master["end"]["dateTime"])
    id = master_id <> "_" <> Calendar.strftime(start, "%Y%m%dT%H%M%SZ")

    instance =
      state.google[id] ||
        master
        |> Map.put("id", id)
        |> Map.put("recurringEventId", master_id)
        |> Map.put("originalStartTime", %{"dateTime" => original, "timeZone" => "Etc/UTC"})
        |> Map.put("start", %{"dateTime" => original, "timeZone" => "Etc/UTC"})
        |> Map.put("end", %{
          "dateTime" =>
            DateTime.to_iso8601(DateTime.add(start, DateTime.diff(master_end, master_start))),
          "timeZone" => "Etc/UTC"
        })
        |> Map.delete("recurrence")
        |> Map.put("_generated", true)

    json(200, %{"items" => [instance]}, %{state | google: Map.put(state.google, id, instance)})
  end

  defp apple_entries(state),
    do:
      Enum.map_join(state.apple, fn {path, resource} ->
        "<d:response><d:href>#{path}</d:href><d:propstat><d:prop><d:getetag>#{resource.etag}</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
      end)

  defp xml(status, content, state),
    do:
      {status, [{"content-type", "application/xml"}],
       "<?xml version=\"1.0\"?><d:multistatus xmlns:d=\"DAV:\" xmlns:c=\"urn:ietf:params:xml:ns:caldav\">#{content}</d:multistatus>",
       state}

  defp json(status, body, state),
    do: {status, [{"content-type", "application/json"}], Jason.encode!(body), state}

  defp etag(state), do: "\"revision-#{state.revision + 1}\""

  defp read_request(socket, bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        size =
          case Regex.run(~r/content-length: (\d+)/i, headers) do
            [_, n] -> String.to_integer(n)
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

defmodule Manifold.Connectors.CalendarSync.Google do
  @moduledoc "Google Calendar v3 adapter with bounded complete snapshots and conditional writes."
  alias Manifold.Calendars.Time, as: CalendarTime
  alias Manifold.Connectors.CalendarConnections
  alias Manifold.Core.HTTPClient
  alias Manifold.Data.{Schema.CalendarBinding, Schema.CalendarConnection}
  alias Manifold.Repo

  @default_base "https://www.googleapis.com/calendar/v3"
  @max_pages 100
  @max_events 5_000
  @database Tzdata.TimeZoneDatabase

  def discover(connection, opts \\ []) do
    with {:ok, items, _token} <- pages(connection, "/users/me/calendarList", [], opts) do
      {:ok,
       Enum.map(items, fn item ->
         writable = item["accessRole"] in ["owner", "writer"]

         %{
           id: item["id"],
           name: item["summaryOverride"] || item["summary"] || item["id"],
           capabilities: %{
             "write" => writable,
             "create" => writable,
             "update" => writable,
             "delete" => writable
           },
           metadata: Map.take(item, ["timeZone", "accessRole", "primary", "backgroundColor"])
         }
       end)}
    end
  end

  def fetch_changes(binding, checkpoint, opts \\ []) do
    connection = connection(binding, opts)
    token = checkpoint["sync_token"]
    params = [showDeleted: "true", singleEvents: "false", maxResults: "2500"]
    params = if token, do: params ++ [syncToken: token], else: params
    mode = if token, do: :delta, else: :full

    case pages(connection, events_path(binding), params, opts) do
      {:ok, items, sync_token} when is_binary(sync_token) and sync_token != "" ->
        with {:ok, snapshots} <- collect(items, &snapshot(&1, binding, connection, opts)) do
          {:ok,
           %{
             complete: true,
             mode: mode,
             checkpoint: %{"sync_token" => sync_token},
             resources: snapshots
           }}
        end

      {:ok, _, _} ->
        {:error, :incomplete_snapshot}

      {:error, :expired_sync_token} when not is_nil(token) ->
        fetch_changes(binding, %{}, opts)

      error ->
        error
    end
  end

  def fetch_resource(resource, opts \\ []) do
    binding =
      Keyword.get_lazy(opts, :binding, fn -> Repo.get!(CalendarBinding, resource.binding_id) end)

    connection = connection(binding, opts)
    url = base(opts) <> events_path(binding) <> "/" <> segment(resource.remote_resource_id)

    case request(connection, :get, url, nil, [], opts) do
      {:ok, item, _headers} ->
        snapshot(item, binding, connection, opts)

      {:error, :not_found} ->
        {:ok,
         %{id: resource.remote_resource_id, href: url, raw: nil, etag: nil, presence: :deleted}}

      {:error, :expired_sync_token} ->
        {:ok,
         %{id: resource.remote_resource_id, href: url, raw: nil, etag: nil, presence: :deleted}}

      error ->
        error
    end
  end

  def destination(binding, resource, opts \\ []) do
    {:ok,
     Map.get(resource, :href) ||
       base(opts) <> events_path(binding) <> "/" <> segment(resource.remote_resource_id)}
  end

  @doc "Resolves a new detached edit against the exact remote original slot before dispatch."
  def resolve_target(binding, resource, opts) do
    metadata = Map.get(resource, :provider_metadata) || %{}
    slot = metadata["original_slot"]

    cond do
      Map.get(resource, :base_raw) != nil -> {:ok, nil}
      slot in [nil, ""] -> {:ok, nil}
      metadata["master_remote_id"] in [nil, ""] -> {:error, :unmapped_series_master}
      not is_map(metadata["master_base_projection"]) -> {:error, :missing_master_baseline}
      true -> resolve_instance(binding, metadata, opts)
    end
  end

  defp resolve_instance(binding, metadata, opts) do
    master = metadata["master_base_projection"]

    source_zone =
      metadata["original_timezone"] || metadata["recurrence_timezone"] || master["timezone"]

    connection = connection(binding, opts)

    with {:ok, original} <- wire_time(metadata["original_slot"], source_zone),
         original_start = original["dateTime"] || original["date"],
         {:ok, instances, _} <-
           pages(
             connection,
             events_path(binding) <> "/" <> segment(metadata["master_remote_id"]) <> "/instances",
             [originalStart: original_start, showDeleted: "true", maxResults: "2500"],
             opts
           ),
         {:ok, instance} <- exact_instance(instances, metadata["original_slot"], source_zone),
         {:ok, expected} <- original_projection(master, metadata["original_slot"], source_zone),
         {:ok, snapshot} <- snapshot(instance, binding, connection, opts) do
      # The coordinator compares this proven target baseline against the fetched
      # candidate before adopting its ETag. A modified instance becomes a conflict.
      {:ok, Map.put(snapshot, :metadata, %{original_projection: expected})}
    end
  end

  defp exact_instance(instances, slot, zone) do
    with {:ok, original} <- CalendarTime.parse(slot, zone) do
      matches =
        Enum.filter(instances, fn instance ->
          with {:ok, value} <- calendar_value(instance["originalStartTime"]),
               {:ok, candidate} <- CalendarTime.parse(value.value, value.timezone) do
            same_instant?(candidate, original)
          else
            _ -> false
          end
        end)

      case matches do
        [instance] -> {:ok, instance}
        [] -> {:error, :remote_instance_not_found}
        _ -> {:error, :ambiguous_remote_instance}
      end
    end
  end

  defp original_projection(master, slot, zone) do
    event = %{
      starts_at: master["starts_at"],
      ends_at: master["ends_at"],
      timezone: master["timezone"]
    }

    viewing_zone = master["timezone"] || "Etc/UTC"

    with {:ok, period} <- CalendarTime.period(event, viewing_zone),
         {:ok, start} <- CalendarTime.parse(slot, zone, viewing_zone) do
      finish =
        if period.all_day do
          Date.add(start, Date.diff(period.ends_at, period.starts_at))
        else
          DateTime.add(start, DateTime.diff(period.ends_at, period.starts_at), :second, @database)
        end

      expected =
        master
        |> Map.put("starts_at", CalendarTime.compact(start))
        |> Map.put("ends_at", CalendarTime.compact(finish))
        |> Map.put("recurrence_id", CalendarTime.compact(start))
        |> Map.put("recurrence_timezone", if(period.all_day, do: nil, else: viewing_zone))
        |> Map.put("recurrence_rules", [])
        |> Map.put("recurrence_dates", [])
        |> Map.put("excluded_dates", [])
        |> Map.put("deleted", false)

      {:ok, expected}
    end
  end

  defp same_instant?(%Date{} = left, %Date{} = right), do: Date.compare(left, right) == :eq

  defp same_instant?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_instant?(_, _), do: false

  def decode(%{presence: :deleted}, _opts), do: {:ok, []}

  def decode(snapshot, _opts) do
    with {:ok, item} when is_map(item) <- Jason.decode(snapshot.raw),
         {:ok, component} <- decode_item(item) do
      {:ok, [component]}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_google_event}
    end
  end

  defp decode_item(item) do
    cancelled = item["status"] == "cancelled"
    start_map = item["start"] || item["originalStartTime"]
    finish_map = item["end"] || start_map
    private = get_in(item, ["extendedProperties", "private"]) || %{}
    uid = private["manifold_uid"] || item["iCalUID"]

    with :ok <- supported_recurrence(item["recurrence"] || []),
         true <- (is_binary(uid) and is_binary(item["id"])) || {:error, :invalid_google_event},
         {:ok, start} <- calendar_value(start_map),
         {:ok, finish} <- calendar_value(finish_map),
         {:ok, rid, recurrence_zone} <- original_slot(item, private),
         {:ok, reminders, reminder_limits} <- decode_reminders(item["reminders"]) do
      recurrence = item["recurrence"] || []

      p = %{
        "summary" => blank(item["summary"]),
        "description" => blank(item["description"]),
        "location" => blank(item["location"]),
        "starts_at" => start.value,
        "ends_at" => finish.value,
        "timezone" => start.timezone,
        "all_day" => start.kind == "date",
        "time_kind" => start.kind,
        "recurrence_id" => rid,
        "recurrence_timezone" => recurrence_zone,
        "recurrence_rules" =>
          for(
            line <- recurrence,
            String.starts_with?(line, "RRULE:"),
            do: String.replace_prefix(line, "RRULE:", "")
          ),
        "recurrence_dates" =>
          Enum.filter(recurrence, &String.starts_with?(&1, ["RDATE:", "RDATE;"])),
        "excluded_dates" =>
          Enum.filter(recurrence, &String.starts_with?(&1, ["EXDATE:", "EXDATE;"])),
        "deleted" => cancelled,
        "reminders" => reminders
      }

      fields =
        if cancelled,
          do: ~w(recurrence_id recurrence_timezone deleted),
          else: Map.keys(p)

      fields = if reminder_limits == [], do: fields, else: List.delete(fields, "reminders")

      {:ok,
       %{
         key: uid <> <<31>> <> rid,
         projection: p,
         fields: fields,
         metadata: %{
           uid: uid,
           series_key: item["recurringEventId"] || item["id"],
           google_ical_uid: item["iCalUID"],
           capability_limits: reminder_limits
         }
       }}
    end
  end

  defp original_slot(item, private) do
    cond do
      is_binary(private["manifold_recurrence_id"]) and private["manifold_recurrence_id"] != "" ->
        {:ok, private["manifold_recurrence_id"], blank(private["manifold_recurrence_timezone"])}

      is_map(item["originalStartTime"]) ->
        original = item["originalStartTime"]

        original =
          if original["timeZone"],
            do: original,
            else: Map.put(original, "timeZone", item["_manifold_original_timezone"])

        with {:ok, slot} <- calendar_value(original), do: {:ok, slot.value, slot.timezone}

      item["recurringEventId"] ->
        {:error, :missing_original_slot}

      true ->
        {:ok, "", nil}
    end
  end

  defp calendar_value(%{"date" => date}) do
    with {:ok, value} <- Date.from_iso8601(date) do
      {:ok, %{value: CalendarTime.compact(value), timezone: nil, kind: "date"}}
    end
  end

  defp calendar_value(%{"dateTime" => value} = source) do
    timezone = blank(source["timeZone"])

    with {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         {:ok, zoned} <- DateTime.shift_zone(datetime, timezone || "Etc/UTC", @database) do
      {:ok,
       %{
         value: CalendarTime.compact(zoned),
         timezone: timezone || "Etc/UTC",
         kind: if(zoned.time_zone in ["Etc/UTC", "UTC"], do: "utc", else: "tzid")
       }}
    end
  end

  defp calendar_value(_), do: {:error, :invalid_google_time}

  def encode(resource, [%{event: event, projection: p}], _opts) do
    with {:ok, previous} <- previous_json(Map.get(resource, :base_raw)),
         :ok <- scheduling_supported(previous),
         :ok <- valid_reminders(p["reminders"] || []),
         {:ok, start} <- wire_time(p["starts_at"], p["timezone"]),
         {:ok, finish} <- wire_finish(p, start) do
      private = get_in(previous, ["extendedProperties", "private"]) || %{}

      private =
        private
        |> Map.put("manifold_uid", event.uid)
        |> Map.put("manifold_recurrence_id", p["recurrence_id"] || "")
        |> Map.put("manifold_recurrence_timezone", p["recurrence_timezone"] || "")

      recurrence =
        Enum.map(
          p["recurrence_rules"] || [],
          &if(String.starts_with?(&1, "RRULE:"), do: &1, else: "RRULE:" <> &1)
        ) ++
          Enum.map(p["recurrence_dates"] || [], &property_line(&1, "RDATE", p)) ++
          Enum.map(p["excluded_dates"] || [], &property_line(&1, "EXDATE", p))

      body = %{
        "summary" => p["summary"] || "",
        "description" => p["description"] || "",
        "location" => p["location"] || "",
        "start" => start,
        "end" => finish,
        "recurrence" => recurrence,
        "extendedProperties" => Map.put(previous["extendedProperties"] || %{}, "private", private)
      }

      body =
        if p["recurrence_id"] not in [nil, ""], do: Map.delete(body, "recurrence"), else: body

      inherited? =
        Map.get(resource, :base_raw) != nil and
          get_in(previous, ["reminders", "useDefault"]) != false

      body =
        if inherited? and (p["reminders"] || []) == [],
          do: body,
          else:
            Map.put(body, "reminders", %{
              "useDefault" => false,
              "overrides" => p["reminders"] || []
            })

      body =
        if is_nil(Map.get(resource, :base_raw)),
          do: Map.put(body, "id", resource.remote_resource_id),
          else: body

      {:ok, Jason.encode!(body)}
    end
  end

  def encode(_, _, _), do: {:error, :google_requires_individual_component_resource}

  defp wire_time(value, timezone) when is_binary(value) do
    cond do
      byte_size(value) == 8 ->
        with {:ok, date} <- CalendarTime.parse(value),
             do: {:ok, %{"date" => Date.to_iso8601(date)}}

      timezone in [nil, ""] and not String.ends_with?(value, "Z") ->
        {:error, :floating_time_not_supported}

      true ->
        zone = if String.ends_with?(value, "Z"), do: "Etc/UTC", else: timezone

        with {:ok, datetime} <- CalendarTime.parse(value, timezone, zone) do
          {:ok, %{"dateTime" => DateTime.to_iso8601(datetime), "timeZone" => zone}}
        end
    end
  end

  defp wire_time(_, _), do: {:error, :invalid_calendar_time}

  defp wire_finish(p, %{"date" => date}) do
    value = p["ends_at"]

    if value in [nil, ""],
      do: {:ok, %{"date" => date |> Date.from_iso8601!() |> Date.add(1) |> Date.to_iso8601()}},
      else: wire_time(value, p["timezone"])
  end

  defp wire_finish(p, _start) do
    if p["ends_at"] in [nil, "", p["starts_at"]],
      do: {:error, :zero_duration_not_supported},
      else: wire_time(p["ends_at"], p["timezone"])
  end

  defp property_line(line, name, p) do
    if String.starts_with?(line, [name <> ":", name <> ";"]) do
      line
    else
      cond do
        p["all_day"] ->
          name <> ";VALUE=DATE:" <> line

        p["timezone"] not in [nil, "", "UTC", "Etc/UTC"] and not String.ends_with?(line, "Z") ->
          name <> ";TZID=" <> p["timezone"] <> ":" <> line

        true ->
          name <> ":" <> line
      end
    end
  end

  def validate_delete(resource, _components, _opts) do
    with {:ok, previous} <- previous_json(Map.get(resource, :base_raw)),
         do: scheduling_supported(previous)
  end

  def execute(attempt, connection, opts \\ []) do
    with :ok <- trusted_url(attempt.destination, opts),
         {:ok, method, destination, headers} <- write_target(attempt),
         {:ok, body, response_headers} <-
           request(
             connection,
             method,
             destination,
             if(method == :delete, do: nil, else: attempt.payload),
             headers,
             opts
           ) do
      if method == :delete do
        {:ok, %{etag: nil, raw: nil}}
      else
        etag = if is_map(body), do: body["etag"], else: header(response_headers, "etag")

        if strong_etag?(etag),
          do: {:ok, %{etag: etag, raw: Jason.encode!(body)}},
          else: {:error, :unknown}
      end
    else
      {:error, reason}
      when reason in [:not_found, :expired_sync_token] and attempt.operation == "delete" ->
        {:ok, %{etag: nil, raw: nil}}

      error ->
        error
    end
  end

  defp write_target(%{operation: "delete", precondition: %{"if_match" => etag}, destination: url}) do
    if strong_etag?(etag),
      do: {:ok, :delete, url, [{"if-match", etag}]},
      else: {:error, :missing_etag}
  end

  defp write_target(%{precondition: %{"if_match" => etag}, destination: url}) do
    if strong_etag?(etag),
      do: {:ok, :patch, url, [{"if-match", etag}]},
      else: {:error, :missing_etag}
  end

  defp write_target(%{
         operation: "upsert",
         precondition: %{"if_none_match" => "*"},
         destination: url
       }) do
    {:ok, :post, url |> String.split("/") |> Enum.drop(-1) |> Enum.join("/"),
     [{"if-none-match", "*"}]}
  end

  defp write_target(_), do: {:error, :missing_precondition}

  defp pages(connection, path, params, opts),
    do: pages(connection, path, params, opts, MapSet.new(), [], 0)

  defp pages(_connection, _path, _params, _opts, _seen, _items, count) when count >= @max_pages,
    do: {:error, :page_limit}

  defp pages(connection, path, params, opts, seen, items, count) do
    query = URI.encode_query(params)

    with {:ok, body, _headers} <-
           request(connection, :get, base(opts) <> path <> "?" <> query, nil, [], opts),
         true <- (is_map(body) and is_list(body["items"])) || {:error, :invalid_google_response},
         all = items ++ body["items"],
         true <- length(all) <= @max_events || {:error, :resource_limit} do
      case body["nextPageToken"] do
        nil ->
          {:ok, all, body["nextSyncToken"]}

        token when is_binary(token) and token != "" ->
          if MapSet.member?(seen, token) do
            {:error, :repeated_page_token}
          else
            pages(
              connection,
              path,
              Keyword.put(params, :pageToken, token),
              opts,
              MapSet.put(seen, token),
              all,
              count + 1
            )
          end

        _ ->
          {:error, :invalid_page_token}
      end
    end
  end

  defp snapshot(item, binding, connection, opts) do
    with true <-
           (is_binary(item["id"]) and
              (strong_etag?(item["etag"]) or item["status"] == "cancelled")) ||
             {:error, :invalid_google_event},
         {:ok, item} <- hydrate_cancelled(item, binding, connection, opts) do
      deleted = item["status"] == "cancelled" and is_nil(item["recurringEventId"])

      {:ok,
       %{
         id: item["id"],
         href: base(opts) <> events_path(binding) <> "/" <> segment(item["id"]),
         raw: Jason.encode!(item),
         etag: item["etag"],
         presence: if(deleted, do: :deleted, else: :present),
         metadata: %{}
       }}
    end
  end

  defp hydrate_cancelled(
         %{"status" => "cancelled", "recurringEventId" => master} = item,
         binding,
         connection,
         opts
       ) do
    if item["iCalUID"] do
      {:ok, item}
    else
      with {:ok, parent, _} <-
             request(
               connection,
               :get,
               base(opts) <> events_path(binding) <> "/" <> segment(master),
               nil,
               [],
               opts
             ) do
        {:ok,
         item
         |> Map.put("iCalUID", parent["iCalUID"])
         |> Map.put("extendedProperties", parent["extendedProperties"])
         |> Map.put("_manifold_original_timezone", get_in(parent, ["start", "timeZone"]))}
      end
    end
  end

  defp hydrate_cancelled(item, _binding, _connection, _opts), do: {:ok, item}

  defp request(connection, method, url, body, extra_headers, opts) do
    with :ok <- trusted_url(url, opts),
         {:ok, credentials} <- CalendarConnections.credentials(connection, opts) do
      options = [
        method: method,
        url: url,
        headers: [
          {"authorization", "Bearer " <> credentials.access_token},
          {"content-type", "application/json"} | extra_headers
        ],
        body: body,
        decode_body: false,
        retry: false,
        redirect: false,
        compressed: false,
        max_body_bytes: 8 * 1024 * 1024,
        receive_timeout: Keyword.get(opts, :timeout, 15_000)
      ]

      options = if opts[:plug], do: Keyword.put(options, :plug, opts[:plug]), else: options

      case HTTPClient.request(options) do
        {:ok, response} ->
          response(response, method)

        {:error, %HTTPClient.TransportError{phase: :pre_transmission}} ->
          {:error, :transport_failure}

        {:error, _} ->
          {:error, if(method in [:post, :patch, :delete], do: :unknown, else: :transport_failure)}
      end
    end
  end

  defp response(%{status: status, body: body, headers: headers}, method)
       when status in 200..299 do
    if body == "" and method == :delete do
      {:ok, %{}, headers}
    else
      case Jason.decode(body) do
        {:ok, decoded} ->
          {:ok, decoded, headers}

        _ ->
          {:error,
           if(method in [:post, :patch, :delete], do: :unknown, else: :invalid_google_response)}
      end
    end
  end

  defp response(%{status: status, headers: headers}, method) do
    case status do
      401 -> {:error, :unauthorized}
      403 -> {:error, :forbidden}
      404 -> {:error, :not_found}
      410 -> {:error, :expired_sync_token}
      409 -> {:error, :conflict}
      412 -> {:error, :conflict}
      429 -> {:error, {:rate_limited, header(headers, "retry-after")}}
      status when status >= 500 and method in [:post, :patch, :delete] -> {:error, :unknown}
      status when status >= 500 -> {:error, :unavailable}
      _ -> {:error, :write_rejected}
    end
  end

  defp trusted_url(url, opts) when is_binary(url) do
    uri = URI.parse(url)
    root = URI.parse(base(opts))

    if uri.scheme == root.scheme and uri.host == root.host and uri.port == root.port and
         uri.userinfo == nil and uri.fragment == nil and
         String.starts_with?(uri.path || "/", String.trim_trailing(root.path || "", "/") <> "/"),
       do: :ok,
       else: {:error, :untrusted_url}
  end

  defp trusted_url(_, _), do: {:error, :untrusted_url}

  defp base(opts),
    do:
      String.trim_trailing(
        Keyword.get(
          opts,
          :google_base_url,
          Keyword.get(
            opts,
            :base_url,
            Application.get_env(:manifold_connectors, :calendar_google_base_url, @default_base)
          )
        ),
        "/"
      )

  defp events_path(binding), do: "/calendars/" <> segment(binding.remote_calendar_id) <> "/events"
  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value
  defp previous_json(nil), do: {:ok, %{}}
  defp previous_json(raw), do: Jason.decode(raw)

  defp supported_recurrence(lines) do
    if is_list(lines) and
         Enum.all?(
           lines,
           &(is_binary(&1) and
               String.starts_with?(&1, ["RRULE:", "RDATE:", "RDATE;", "EXDATE:", "EXDATE;"]))
         ),
       do: :ok,
       else: {:error, :unsupported_recurrence_property}
  end

  defp decode_reminders(%{"useDefault" => false} = value) do
    reminders = value["overrides"] || []

    case valid_reminders(reminders) do
      :ok -> {:ok, Enum.sort_by(reminders, &{&1["method"], &1["minutes"]}), []}
      {:error, _} -> {:ok, [], ["unsupported_reminders"]}
    end
  end

  defp decode_reminders(_), do: {:ok, [], ["inherited_default_reminders"]}

  defp valid_reminders(reminders) do
    valid? =
      is_list(reminders) and length(reminders) <= 5 and
        Enum.all?(reminders, fn
          %{"method" => method, "minutes" => minutes} ->
            method in ["popup", "email"] and is_integer(minutes) and minutes >= 0 and
              minutes <= 40_320

          _ ->
            false
        end)

    if valid?, do: :ok, else: {:error, :unsupported_reminders}
  end

  defp scheduling_supported(%{"attendees" => attendees})
       when is_list(attendees) and attendees != [],
       do: {:error, :scheduling_not_supported}

  defp scheduling_supported(%{"eventType" => type}) when type != "default",
    do: {:error, :event_type_not_supported}

  defp scheduling_supported(_), do: :ok

  defp connection(binding, opts),
    do:
      Keyword.get_lazy(opts, :connection, fn ->
        Repo.get!(CalendarConnection, binding.connection_id)
      end)

  defp header(headers, name), do: headers |> Map.get(name, []) |> List.wrap() |> List.first()

  defp strong_etag?(etag),
    do: is_binary(etag) and Regex.match?(~r/\A"[^"\x00-\x20\x7f]*"\z/, etag)

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end
end

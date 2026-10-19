defmodule Manifold.Calendars.Recurrence do
  @moduledoc """
  Bounded, read-only occurrence projection for local calendar components.

  RRule expands RFC 5545 rules; RDATE, EXDATE and detached components are merged
  by their original recurrence instant. The range has an exclusive end. Errors
  are returned with their event ID, including the engine's expansion limit,
  rather than presenting a silently incomplete calendar.
  """

  alias Manifold.Calendars.Time, as: CalendarTime

  @database Tzdata.TimeZoneDatabase
  @limit 65_535

  def occurrences(events, first_date, until_date, viewing_timezone \\ "Etc/UTC") do
    if Date.compare(first_date, until_date) == :lt do
      events
      |> Enum.group_by(&series_key/1)
      |> Enum.reduce({[], []}, fn {_key, components}, {occurrences, errors} ->
        case project_series(components, first_date, until_date, viewing_timezone) do
          {:ok, projected} ->
            {projected ++ occurrences, errors}

          {:error, event, reason} ->
            {occurrences, [%{event_id: Map.get(event, :id), reason: reason} | errors]}
        end
      end)
      |> result()
    else
      {:error, [%{event_id: nil, reason: :invalid_range}]}
    end
  end

  defp project_series(components, first, until, zone) do
    {masters, exceptions} =
      Enum.split_with(components, &(Map.get(&1, :recurrence_id) in [nil, ""]))

    case masters do
      [] -> project_detached(exceptions, first, until, zone)
      [master] -> project_master(master, exceptions, first, until, zone)
      [master | _] -> {:error, master, :duplicate_series_master}
    end
  end

  defp project_master(%{deleted_at: deleted}, _exceptions, _first, _until, _zone)
       when not is_nil(deleted),
       do: {:ok, []}

  defp project_master(master, exceptions, first, until, zone) do
    with {:ok, period} <- CalendarTime.period(master, zone),
         {:ok, bounds} <- bounds(first, until, period.all_day, zone),
         {:ok, starts} <- starts(master, period, bounds, zone),
         {:ok, excluded} <- property_times(Map.get(master, :excluded_dates, []), master, zone),
         :ok <- same_types(excluded, period.all_day),
         {:ok, overrides} <- exception_keys(exceptions, master, zone),
         {:ok, detached} <- project_detached(exceptions, first, until, zone, master) do
      suppressed = MapSet.new(Enum.map(excluded, &identity/1) ++ overrides)
      recurring = recurring?(master)

      projected =
        starts
        |> Enum.uniq_by(&identity/1)
        |> Enum.reject(&MapSet.member?(suppressed, identity(&1)))
        |> Enum.map(fn start ->
          shifted = %{period | starts_at: start, ends_at: add_duration(start, duration(period))}
          rid = if recurring, do: source_identity(start, master, zone), else: ""
          occurrence(master, master, rid, shifted)
        end)
        |> Enum.filter(&overlaps?(&1, bounds))

      {:ok, projected ++ detached}
    else
      {:error, _event, _reason} = error -> error
      {:error, reason} -> {:error, master, reason}
    end
  end

  defp starts(master, period, bounds, zone) do
    with {:ok, generated} <- rule_starts(master, period, bounds, zone),
         {:ok, additional} <-
           property_times(Map.get(master, :recurrence_dates, []), master, zone),
         :ok <- same_types([period.starts_at | generated ++ additional], period.all_day) do
      {:ok, [period.starts_at | generated ++ additional]}
    end
  end

  defp rule_starts(master, period, bounds, zone) do
    rules = Map.get(master, :recurrence_rules, []) || []

    with {:ok, groups} <- collect(rules, &expand_rule(&1, master, period, bounds, zone)) do
      {:ok, List.flatten(groups)}
    end
  end

  # The native engine's local-time gap handling shifts invalid times. RFC 5545
  # requires generated gaps to be skipped and not counted. Keep all calendar
  # rule arithmetic in the engine, then resolve its wall-clock candidates with
  # the same IANA database used by display. COUNT and UNTIL apply after that.
  defp expand_rule(rule, master, period, bounds, zone) do
    {start, source_zone} =
      CalendarTime.property_value(master.starts_at, Map.get(master, :timezone))

    utc? = String.ends_with?(start, "Z") or period.all_day
    source_zone = if utc?, do: "Etc/UTC", else: normalize_zone(source_zone || zone)

    synthetic_start =
      if period.all_day, do: start <> "T000000Z", else: String.trim_trailing(start, "Z") <> "Z"

    with {:ok, parts, count, until_value} <- rule_parts(rule),
         {:ok, until} <- until_time(until_value, master, period, zone),
         {:ok, origin} <- CalendarTime.parse(synthetic_start),
         document = "DTSTART:#{synthetic_start}\nRRULE:#{Enum.join(parts, ";")}",
         lower =
           if(count,
             do: DateTime.add(origin, -1),
             else: DateTime.add(bounds.utc_first, -duration_seconds(period) - 172_800)
           ),
         upper = DateTime.add(bounds.utc_until, 172_800),
         {:ok, {candidates, limited}} <- engine_between(document, lower, upper),
         {:ok, values} <- resolve_candidates(candidates, source_zone, period, zone, origin),
         :ok <- complete?(limited) do
      values = if until, do: Enum.take_while(values, &(compare(&1, until) != :gt)), else: values
      {:ok, if(count, do: Enum.take(values, count), else: values)}
    end
  end

  defp rule_parts(rule) when is_binary(rule) do
    if String.contains?(rule, ["\r", "\n"]) do
      {:error, {:invalid_recurrence_rule, :invalid_content_line}}
    else
      parts = rule |> String.replace_prefix("RRULE:", "") |> String.split(";")
      pairs = Enum.map(parts, &String.split(&1, "=", parts: 2))
      names = Enum.map(pairs, &hd/1)

      if Enum.all?(pairs, &(length(&1) == 2)) and Enum.uniq(names) == names do
        options = Map.new(pairs, fn [key, value] -> {key, value} end)

        with {:ok, count} <- parse_count(options["COUNT"]),
             false <- count != nil and options["UNTIL"] != nil do
          remaining = Enum.reject(parts, &String.starts_with?(&1, ["COUNT=", "UNTIL="]))
          {:ok, remaining, count, options["UNTIL"]}
        else
          true -> {:error, {:invalid_recurrence_rule, :count_and_until}}
          {:error, _} = error -> error
        end
      else
        {:error, {:invalid_recurrence_rule, :invalid_rule_parts}}
      end
    end
  end

  defp rule_parts(_), do: {:error, {:invalid_recurrence_rule, :invalid_content_line}}
  defp parse_count(nil), do: {:ok, nil}

  defp parse_count(value) do
    case Integer.parse(value) do
      {count, ""} when count > 0 -> {:ok, count}
      _ -> {:error, {:invalid_recurrence_rule, :invalid_count}}
    end
  end

  defp until_time(nil, _master, _period, _zone), do: {:ok, nil}

  defp until_time(value, master, period, zone) do
    with {:ok, until} <- CalendarTime.parse(value, Map.get(master, :timezone), zone),
         :ok <- same_types([until], period.all_day) do
      {:ok, until}
    else
      {:error, reason} -> {:error, {:invalid_recurrence_rule, {:invalid_until, reason}}}
    end
  end

  defp engine_between(document, lower, upper) do
    case RRule.all_between(document, lower, upper, @limit) do
      {:ok, _} = result -> result
      {:error, reason} -> {:error, {:invalid_recurrence_rule, reason}}
    end
  end

  defp resolve_candidates(candidates, source_zone, period, zone, origin) do
    Enum.reduce_while(candidates, {:ok, []}, fn candidate, {:ok, acc} ->
      result =
        cond do
          period.all_day -> {:ok, DateTime.to_date(candidate)}
          candidate == origin -> {:ok, period.starts_at}
          true -> resolve_wall(candidate, source_zone, zone)
        end

      case result do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :gap -> {:cont, {:ok, acc}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp resolve_wall(candidate, source_zone, zone) do
    case DateTime.from_naive(DateTime.to_naive(candidate), source_zone, @database) do
      {:ok, value} -> DateTime.shift_zone(value, normalize_zone(zone), @database)
      {:ambiguous, first, _second} -> DateTime.shift_zone(first, normalize_zone(zone), @database)
      {:gap, _before, _after} -> :gap
      {:error, _} = error -> error
    end
  end

  defp complete?(false), do: :ok
  defp complete?(true), do: {:error, :recurrence_limit_exceeded}
  defp compare(%Date{} = left, %Date{} = right), do: Date.compare(left, right)
  defp compare(%DateTime{} = left, %DateTime{} = right), do: DateTime.compare(left, right)

  defp property_times(lines, master, zone) do
    lines
    |> List.wrap()
    |> Enum.flat_map(fn line ->
      {values, source_zone} = CalendarTime.property_value(line, Map.get(master, :timezone))
      Enum.map(String.split(values, ",", trim: true), &{&1, source_zone})
    end)
    |> collect(fn {value, source_zone} -> CalendarTime.parse(value, source_zone, zone) end)
  end

  defp exception_keys(exceptions, master, zone) do
    collect(exceptions, fn event ->
      source_zone = Map.get(event, :recurrence_timezone) || Map.get(master, :timezone)

      case CalendarTime.parse(Map.get(event, :recurrence_id), source_zone, zone) do
        {:ok, value} -> {:ok, identity(value)}
        {:error, reason} -> {:error, {:invalid_recurrence_id, reason}}
      end
    end)
  end

  defp project_detached(events, first, until, zone, master \\ nil) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, projected} ->
      if Map.get(event, :deleted_at) do
        {:cont, {:ok, projected}}
      else
        with {:ok, period} <- CalendarTime.period(event, zone),
             {:ok, range} <- bounds(first, until, period.all_day, zone) do
          item = occurrence(event, master || event, Map.get(event, :recurrence_id, ""), period)
          {:cont, {:ok, if(overlaps?(item, range), do: [item | projected], else: projected)}}
        else
          {:error, reason} -> {:halt, {:error, event, reason}}
        end
      end
    end)
  end

  defp occurrence(event, master, rid, period) do
    Map.merge(period, %{
      event: event,
      event_id: Map.get(event, :id),
      master_id: Map.get(master, :id),
      recurrence_id: rid,
      date: if(period.all_day, do: period.starts_at, else: DateTime.to_date(period.starts_at)),
      clock: if(period.all_day, do: "All day", else: Calendar.strftime(period.starts_at, "%H:%M"))
    })
  end

  defp bounds(first, until, true, _zone) do
    {:ok,
     %{
       first: first,
       until: until,
       utc_first: DateTime.new!(first, ~T[00:00:00]),
       utc_until: DateTime.new!(until, ~T[00:00:00])
     }}
  end

  defp bounds(first, until, false, zone) do
    with {:ok, start} <-
           CalendarTime.parse(CalendarTime.compact(first) <> "T000000", zone, "Etc/UTC"),
         {:ok, finish} <-
           CalendarTime.parse(CalendarTime.compact(until) <> "T000000", zone, "Etc/UTC") do
      {:ok, %{first: start, until: finish, utc_first: start, utc_until: finish}}
    end
  end

  defp overlaps?(%{starts_at: %Date{} = start, ends_at: finish}, bounds),
    do: Date.compare(start, bounds.until) == :lt and Date.compare(finish, bounds.first) == :gt

  defp overlaps?(%{starts_at: start, ends_at: finish}, bounds) do
    DateTime.compare(start, bounds.until) == :lt and
      (DateTime.compare(finish, bounds.first) == :gt or
         (DateTime.compare(start, finish) == :eq and DateTime.compare(start, bounds.first) != :lt))
  end

  defp duration(%{starts_at: %Date{} = start, ends_at: finish}),
    do: {:days, Date.diff(finish, start)}

  defp duration(%{starts_at: start, ends_at: finish}),
    do: {:seconds, DateTime.diff(finish, start, :second)}

  defp duration_seconds(period) do
    case duration(period) do
      {:days, days} -> days * 86_400
      {:seconds, seconds} -> seconds
    end
  end

  defp add_duration(start, {:days, days}), do: Date.add(start, days)

  defp add_duration(start, {:seconds, seconds}),
    do: DateTime.add(start, seconds, :second, @database)

  defp source_identity(%Date{} = date, _master, _zone), do: CalendarTime.compact(date)

  defp source_identity(datetime, master, zone) do
    {source, source_zone} =
      CalendarTime.property_value(master.starts_at, Map.get(master, :timezone))

    if String.ends_with?(source, "Z") do
      datetime |> DateTime.shift_zone!("Etc/UTC", @database) |> CalendarTime.compact()
    else
      datetime
      |> DateTime.shift_zone!(normalize_zone(source_zone || zone), @database)
      |> Calendar.strftime("%Y%m%dT%H%M%S")
    end
  end

  defp same_types(values, all_day) do
    if Enum.all?(values, &(match?(%Date{}, &1) == all_day)),
      do: :ok,
      else: {:error, :mixed_calendar_time_types}
  end

  defp identity(%Date{} = date), do: {:date, Date.to_gregorian_days(date)}
  defp identity(%DateTime{} = datetime), do: {:instant, DateTime.to_unix(datetime)}

  defp series_key(event) do
    identity = Map.get(event, :series_id) || Map.get(event, :uid) || Map.get(event, :id)
    {Map.get(event, :calendar_id), identity}
  end

  defp recurring?(event),
    do:
      (Map.get(event, :recurrence_rules, []) || []) != [] or
        (Map.get(event, :recurrence_dates, []) || []) != []

  defp normalize_zone("UTC"), do: "Etc/UTC"
  defp normalize_zone(zone), do: zone

  defp collect(values, fun) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp result({values, []}),
    do:
      {:ok,
       Enum.sort_by(
         values,
         &{Date.to_gregorian_days(&1.date), &1.clock, &1.event_id, &1.recurrence_id}
       )}

  defp result({_values, errors}), do: {:error, Enum.reverse(errors)}
end

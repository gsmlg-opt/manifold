defmodule Manifold.Connectors.DAV.ICalendar do
  @moduledoc false
  alias Manifold.Connectors.DAV.ContentLine, as: Line

  def parse(raw) do
    with {:ok, props} <- Line.parse(raw),
         [%{name: "BEGIN", value: "VCALENDAR"} | _] <- props,
         %{name: "END", value: "VCALENDAR"} <- List.last(props),
         true <- one_calendar?(props),
         {:ok, events} <- components(props),
         true <-
           events != [] and length(events) <= 1000 and
             byte_size(raw) * max(1, length(events)) <= 8 * 1024 * 1024 do
      Enum.reduce_while(events, {:ok, []}, fn event, {:ok, acc} ->
        case project(event, raw) do
          {:ok, attrs} -> {:cont, {:ok, [attrs | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, events} ->
          identities = Enum.map(events, &{&1.uid, &1.recurrence_id})

          if length(identities) == MapSet.size(MapSet.new(identities)),
            do: {:ok, Enum.reverse(events)},
            else: {:error, :duplicate_event}

        error ->
          error
      end
    else
      _ -> {:error, :invalid_icalendar}
    end
  end

  defp one_calendar?(props) do
    Enum.count(props, &(&1.name == "BEGIN" and &1.value == "VCALENDAR")) == 1 and
      Enum.count(props, &(&1.name == "END" and &1.value == "VCALENDAR")) == 1
  end

  defp components(props) do
    Enum.reduce_while(props, {:ok, [], nil, [], []}, fn prop,
                                                        {:ok, stack, current, events, calendar} ->
      case prop do
        %{name: "BEGIN", value: name} ->
          invalid_parent =
            cond do
              name == "VCALENDAR" -> stack != []
              name == "VEVENT" -> stack != ["VCALENDAR"]
              true -> stack == []
            end

          if length(stack) >= 16 or invalid_parent do
            {:halt, {:error, :invalid_component}}
          else
            current =
              cond do
                name == "VEVENT" -> []
                not is_nil(current) -> [prop | current]
                true -> current
              end

            {:cont, {:ok, [name | stack], current, events, calendar}}
          end

        %{name: "END", value: name} ->
          case stack do
            [^name | tail] when name == "VEVENT" ->
              {:cont, {:ok, tail, nil, [Enum.reverse(current) | events], calendar}}

            [^name | tail] ->
              current = if is_nil(current), do: nil, else: [prop | current]
              {:cont, {:ok, tail, current, events, calendar}}

            _ ->
              {:halt, {:error, :invalid_component}}
          end

        _ ->
          case stack do
            [] ->
              {:halt, {:error, :invalid_component}}

            ["VCALENDAR"] ->
              {:cont, {:ok, stack, current, events, [prop | calendar]}}

            _ ->
              {:cont,
               {:ok, stack, if(is_nil(current), do: nil, else: [prop | current]), events,
                calendar}}
          end
      end
    end)
    |> case do
      {:ok, [], nil, events, calendar} ->
        case Line.all(calendar, "VERSION") do
          [%{value: "2.0"}] -> {:ok, Enum.reverse(events)}
          _ -> {:error, :invalid_component}
        end

      _ ->
        {:error, :invalid_component}
    end
  end

  defp project(props, raw) do
    {props, alarms} = event_properties(props)
    {reminders, unsupported_alarms} = project_alarms(alarms)
    uid = Line.first(props, "UID")
    recurrence = Enum.find(props, &(&1.name == "RECURRENCE-ID"))
    canceled? = Line.first(props, "STATUS") == "CANCELLED"

    start =
      Enum.find(props, &(&1.name == "DTSTART")) ||
        if(canceled? and not is_nil(recurrence), do: recurrence)

    if (is_binary(uid) and uid != "" and start) && valid_date?(start.value) do
      stop = Line.first(props, "DTEND", "")

      if stop == "" or valid_date?(stop) do
        {:ok,
         %{
           uid: uid,
           deleted: canceled?,
           recurrence_id: Line.first(props, "RECURRENCE-ID", ""),
           recurrence_timezone: if(recurrence, do: Map.get(recurrence.params, "TZID")),
           time_kind:
             cond do
               byte_size(start.value) == 8 -> "date"
               String.ends_with?(start.value, "Z") -> "utc"
               Map.has_key?(start.params, "TZID") -> "tzid"
               true -> "floating"
             end,
           raw: raw,
           summary: text(props, "SUMMARY"),
           description: text(props, "DESCRIPTION"),
           location: text(props, "LOCATION"),
           starts_at: start.value,
           ends_at: stop,
           timezone:
             Map.get(
               start.params,
               "TZID",
               if(String.ends_with?(start.value, "Z"), do: "Etc/UTC", else: "")
             ),
           all_day: Map.get(start.params, "VALUE") == "DATE" or byte_size(start.value) == 8,
           recurrence_rules: Enum.map(Line.all(props, "RRULE"), & &1.value),
           recurrence_dates: date_properties(props, "RDATE"),
           excluded_dates: date_properties(props, "EXDATE"),
           reminders: reminders,
           unsupported_alarms: unsupported_alarms
         }}
      else
        {:error, :invalid_event_date}
      end
    else
      {:error, :invalid_event}
    end
  end

  defp event_properties(props) do
    {top, nested, _, _} =
      Enum.reduce(props, {[], [], [], 0}, fn prop, {top, nested, current, depth} ->
        cond do
          prop.name == "BEGIN" ->
            {top, nested, [prop | current], depth + 1}

          prop.name == "END" and depth == 1 ->
            {top, [Enum.reverse([prop | current]) | nested], [], 0}

          prop.name == "END" ->
            {top, nested, [prop | current], depth - 1}

          depth == 0 ->
            {[prop | top], nested, current, depth}

          true ->
            {top, nested, [prop | current], depth}
        end
      end)

    {Enum.reverse(top), Enum.reverse(nested)}
  end

  defp project_alarms(alarms) do
    Enum.reduce(alarms, {[], false}, fn alarm, {reminders, unsupported} ->
      case project_alarm(alarm) do
        {:ok, reminder} -> {[reminder | reminders], unsupported}
        _ -> {reminders, true}
      end
    end)
    |> then(fn {values, unsupported} ->
      values = values |> Enum.uniq() |> Enum.sort_by(&{&1["method"], &1["minutes"]})
      {values, unsupported or length(values) > 5}
    end)
  end

  defp project_alarm([%{name: "BEGIN", value: "VALARM"} | _] = alarm) do
    triggers = Line.all(alarm, "TRIGGER")
    allowed = ~w(BEGIN END ACTION TRIGGER DESCRIPTION)

    with true <- Enum.all?(alarm, &(&1.name in allowed)),
         true <- Enum.count(alarm, &(&1.name == "BEGIN")) == 1,
         [%{value: "DISPLAY"}] <- Line.all(alarm, "ACTION"),
         [%{value: duration, params: params}] <- triggers,
         true <-
           Enum.all?(params, fn {key, value} ->
             {key, value} in [{"RELATED", "START"}, {"VALUE", "DURATION"}]
           end),
         {:ok, minutes} <- reminder_minutes(duration) do
      {:ok, %{"method" => "popup", "minutes" => minutes}}
    else
      _ -> :unsupported
    end
  end

  defp project_alarm(_), do: :unsupported

  defp reminder_minutes(duration) do
    case Regex.run(~r/\A(-)?P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?\z/, duration,
           capture: :all_but_first
         ) do
      matches when is_list(matches) ->
        [sign, days, hours, minutes, seconds] = Enum.take(matches ++ List.duplicate("", 5), 5)

        values =
          Enum.map([days, hours, minutes, seconds], fn value ->
            if value == "", do: 0, else: String.to_integer(value)
          end)

        [d, h, m, s] = values
        total = d * 86_400 + h * 3_600 + m * 60 + s

        if Enum.any?([days, hours, minutes, seconds], &(&1 != "")) and (sign == "-" or total == 0) and
             rem(total, 60) == 0 and total <= 40_320 * 60,
           do: {:ok, div(total, 60)},
           else: :unsupported

      _ ->
        :unsupported
    end
  end

  defp date_properties(props, name) do
    Enum.flat_map(Line.all(props, name), fn property ->
      if map_size(property.params) == 0 do
        String.split(property.value, ",")
      else
        head =
          property.params
          |> Enum.sort()
          |> Enum.map_join("", fn {key, val} -> ";#{key}=#{val}" end)

        [name <> head <> ":" <> property.value]
      end
    end)
  end

  defp valid_date?(value) do
    case Regex.run(~r/\A(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?\z/, value) do
      [_, year, month, day] ->
        valid_day?(year, month, day)

      [_, year, month, day, hour, minute, second] ->
        valid_day?(year, month, day) and String.to_integer(hour) < 24 and
          String.to_integer(minute) < 60 and String.to_integer(second) <= 60

      _ ->
        false
    end
  end

  defp valid_day?(year, month, day),
    do:
      match?(
        {:ok, _},
        Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day))
      )

  defp text(props, key), do: Line.first(props, key, "") |> Line.unescape()
end

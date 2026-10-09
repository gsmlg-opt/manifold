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
            {:cont,
             {:ok, [name | stack], if(name == "VEVENT", do: [], else: current), events, calendar}}
          end

        %{name: "END", value: name} ->
          case stack do
            [^name | tail] when name == "VEVENT" ->
              {:cont, {:ok, tail, nil, [Enum.reverse(current) | events], calendar}}

            [^name | tail] ->
              {:cont, {:ok, tail, current, events, calendar}}

            _ ->
              {:halt, {:error, :invalid_component}}
          end

        _ ->
          case stack do
            [] -> {:halt, {:error, :invalid_component}}
            ["VEVENT" | _] -> {:cont, {:ok, stack, [prop | current], events, calendar}}
            ["VCALENDAR"] -> {:cont, {:ok, stack, current, events, [prop | calendar]}}
            _ -> {:cont, {:ok, stack, current, events, calendar}}
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
    uid = Line.first(props, "UID")
    start = Enum.find(props, &(&1.name == "DTSTART"))

    if (is_binary(uid) and uid != "" and start) && valid_date?(start.value) do
      stop = Line.first(props, "DTEND", "")

      if stop == "" or valid_date?(stop) do
        {:ok,
         %{
           uid: uid,
           recurrence_id: Line.first(props, "RECURRENCE-ID", ""),
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
           excluded_dates: Enum.flat_map(Line.all(props, "EXDATE"), &String.split(&1.value, ","))
         }}
      else
        {:error, :invalid_event_date}
      end
    else
      {:error, :invalid_event}
    end
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

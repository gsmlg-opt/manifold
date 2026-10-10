defmodule Manifold.Connectors.DAV.Document do
  @moduledoc false
  alias Manifold.Connectors.DAV.{VCard, ICalendar, ContentLine}
  @limit 8 * 1024 * 1024

  def scheduling?(raw) when is_binary(raw) do
    case ContentLine.parse(raw) do
      {:ok, lines} -> Enum.any?(lines, &(&1.name in ["ORGANIZER", "ATTENDEE"]))
      _ -> false
    end
  end

  def scheduling?(_), do: false

  def delete_calendar(nil), do: {:ok, :empty}

  def delete_calendar(raw) do
    with true <- not scheduling?(raw) || {:error, :scheduling_not_supported},
         {:ok, _} <- ICalendar.parse(raw),
         {:ok, lines} <- tokenize(raw),
         :ok <- safe_complete_deletion(lines),
         do: {:ok, :empty}
  end

  defp safe_complete_deletion(lines) do
    Enum.reduce_while(lines, 0, fn line, depth ->
      cond do
        line.name == "BEGIN" and depth == 1 and line.value not in ["VEVENT", "VTIMEZONE"] ->
          {:halt, {:error, :unsupported_calendar_components}}

        line.name == "BEGIN" ->
          {:cont, depth + 1}

        line.name == "END" ->
          {:cont, depth - 1}

        true ->
          {:cont, depth}
      end
    end)
    |> case do
      0 -> :ok
      {:error, _} = error -> error
      _ -> {:error, :invalid_document}
    end
  end

  def contact(raw, attrs, uid) do
    with {:ok, raw} <- contact_base(raw, uid),
         {:ok, base} <- VCard.parse(raw),
         true <- base.uid == uid || {:error, :identity_changed},
         {:ok, lines} <- tokenize(raw) do
      fields = [
        full_name: "FN",
        given_name: "N",
        family_name: "N",
        organization: "ORG",
        notes: "NOTE"
      ]

      changed =
        Enum.filter(fields, fn {field, _} ->
          value(attrs, field, Map.get(base, field)) != Map.get(base, field)
        end)

      lines =
        Enum.reduce(Enum.uniq_by(changed, &elem(&1, 1)), lines, fn {_, prop}, acc ->
          replacement =
            case prop do
              "N" ->
                old = Enum.find(acc, &(&1.name == "N"))
                parts = if old, do: ContentLine.split(old.value, ";"), else: []

                [
                  escape(value(attrs, :family_name, base.family_name)),
                  escape(value(attrs, :given_name, base.given_name))
                  | Enum.map(2..4, &Enum.at(parts, &1, ""))
                ]
                |> Enum.join(";")

              "ORG" ->
                old = Enum.find(acc, &(&1.name == "ORG"))
                tail = if old, do: Enum.drop(ContentLine.split(old.value, ";"), 1), else: []
                Enum.join([escape(value(attrs, :organization, base.organization)) | tail], ";")

              _ ->
                field =
                  Enum.find_value(fields, fn {field, name} -> if name == prop, do: field end)

                escape(value(attrs, field, Map.get(base, field)))
            end

          replace_property(acc, prop, replacement)
        end)

      lines =
        Enum.reduce([emails: "EMAIL", phones: "TEL", addresses: "ADR"], lines, fn {field, name},
                                                                                  acc ->
          desired = value(attrs, field, Map.get(base, field))

          if desired == Map.get(base, field),
            do: acc,
            else: replace_values(acc, name, desired, field)
        end)

      result = render(lines)
      with {:ok, _} <- VCard.parse(result), do: {:ok, result}
    else
      false -> {:error, :invalid_document}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :invalid_document}
  end

  def event(raw, attrs, uid, recurrence_id \\ "") do
    with {:ok, raw} <- event_base(raw, uid),
         true <- not scheduling?(raw) || {:error, :scheduling_not_supported},
         {:ok, projections} <- ICalendar.parse(raw),
         {:ok, lines} <- tokenize(raw),
         {:ok, first, last} <- event_range(lines, uid, recurrence_id),
         base when not is_nil(base) <-
           Enum.find(projections, &(&1.uid == uid and &1.recurrence_id == recurrence_id)) do
      component = Enum.slice(lines, first..last)

      props = [
        summary: "SUMMARY",
        description: "DESCRIPTION",
        location: "LOCATION",
        starts_at: "DTSTART",
        ends_at: "DTEND"
      ]

      component =
        Enum.reduce(props, component, fn {field, name}, acc ->
          desired = value(attrs, field, Map.get(base, field))

          time_changed =
            field in [:starts_at, :ends_at] and
              (value(attrs, :timezone, base.timezone) != base.timezone or
                 value(attrs, :all_day, base.all_day) != base.all_day)

          if desired == Map.get(base, field) and not time_changed do
            acc
          else
            if field in [:starts_at, :ends_at] do
              if desired in [nil, ""] do
                remove_top_property(acc, name)
              else
                header = time_header(name, attrs, base, top_property(acc, name))
                acc = if name == "DTEND", do: remove_top_property(acc, "DURATION"), else: acc
                replace_top_property(acc, name, header, to_string(desired))
              end
            else
              existing = top_property(acc, name)

              replace_top_property(
                acc,
                name,
                if(existing, do: existing.head, else: name),
                escape(desired)
              )
            end
          end
        end)

      result = render(Enum.take(lines, first) ++ component ++ Enum.drop(lines, last + 1))
      with {:ok, _} <- ICalendar.parse(result), do: {:ok, result}
    else
      nil -> {:error, :event_not_found}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :invalid_document}
  end

  def delete_event(raw, uid, recurrence_id) do
    with true <- not scheduling?(raw) || {:error, :scheduling_not_supported},
         {:ok, _} <- ICalendar.parse(raw),
         {:ok, lines} <- tokenize(raw),
         {:ok, ranges} <- event_ranges(lines) do
      selected =
        Enum.filter(ranges, fn {first, last} ->
          props = Enum.slice(lines, first..last)

          property(props, "UID") == uid and
            (recurrence_id == :series or property(props, "RECURRENCE-ID", "") == recurrence_id)
        end)

      if selected == [] do
        {:error, :event_not_found}
      else
        removed =
          selected
          |> Enum.flat_map(fn {first, last} -> Enum.to_list(first..last) end)
          |> MapSet.new()

        kept =
          lines
          |> Enum.with_index()
          |> Enum.reject(fn {_, i} -> MapSet.member?(removed, i) end)
          |> Enum.map(&elem(&1, 0))

        if length(selected) == length(ranges) do
          with :ok <- safe_complete_deletion(lines), do: {:ok, :empty}
        else
          {:ok, render(kept)}
        end
      end
    end
  rescue
    _ -> {:error, :invalid_document}
  end

  # Tolerate folding, property order and provider-maintained revision timestamps.
  # Compare complete component trees, including unknown properties and alarms.
  def equivalent?(left, right) do
    with {:ok, a} <- tokenize(left),
         {:ok, b} <- tokenize(right),
         {:ok, a} <- comparison(a),
         {:ok, b} <- comparison(b) do
      a == b
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp comparison(lines) do
    {stack, roots} =
      Enum.reduce(lines, {[], []}, fn line, {stack, roots} ->
        cond do
          line.name == "BEGIN" ->
            {[{line.value, []} | stack], roots}

          line.name == "END" ->
            [{name, contents} | rest] = stack
            if name != line.value, do: raise(ArgumentError, "invalid component")
            component = {name, Enum.sort(contents)}

            case rest do
              [] -> {[], [component | roots]}
              [{parent, contents} | tail] -> {[{parent, [component | contents]} | tail], roots}
            end

          true ->
            [{name, contents} | rest] = stack

            managed =
              (name == "VCARD" and line.name == "REV") or
                (name == "VEVENT" and line.name in ["DTSTAMP", "LAST-MODIFIED"]) or
                (name == "VCALENDAR" and line.name == "PRODID")

            contents = if managed, do: contents, else: [line.logical | contents]
            {[{name, contents} | rest], roots}
        end
      end)

    if stack == [] and roots != [], do: {:ok, Enum.sort(roots)}, else: :invalid
  end

  defp contact_base(nil, uid),
    do:
      {:ok, "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:#{escape(uid)}\r\nFN:New contact\r\nEND:VCARD\r\n"}

  defp contact_base(raw, _), do: {:ok, raw}

  defp event_base(nil, uid),
    do:
      {:ok,
       "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Manifold//Calendar//EN\r\nBEGIN:VEVENT\r\nUID:#{escape(uid)}\r\nDTSTAMP:#{Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")}\r\nDTSTART:19700101T000000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"}

  defp event_base(raw, _), do: {:ok, raw}

  defp tokenize(raw) when is_binary(raw) and byte_size(raw) <= @limit do
    if String.valid?(raw) and not String.contains?(raw, <<0>>) do
      physical =
        Regex.scan(~r/[^\r\n]*(?:\r\n|\n|\r|$)/, raw)
        |> List.flatten()
        |> Enum.reject(&(&1 == ""))

      logical =
        Enum.reduce(physical, [], fn line, acc ->
          if String.starts_with?(line, [" ", "\t"]) do
            case acc do
              [previous | tail] ->
                [
                  %{
                    previous
                    | raw: previous.raw <> line,
                      logical:
                        previous.logical <>
                          (line
                           |> String.trim_trailing("\n")
                           |> String.trim_trailing("\r")
                           |> binary_part(
                             1,
                             byte_size(
                               String.trim_trailing(String.trim_trailing(line, "\n"), "\r")
                             ) - 1
                           ))
                  }
                  | tail
                ]

              [] ->
                throw(:invalid_document)
            end
          else
            [
              %{
                raw: line,
                logical: line |> String.trim_trailing("\n") |> String.trim_trailing("\r")
              }
              | acc
            ]
          end
        end)
        |> Enum.reverse()

      if length(logical) > 50_000, do: throw(:invalid_document)

      parsed =
        Enum.map(logical, fn line ->
          {head, content} = split_content(line.logical)
          token = head |> String.split(";", parts: 2) |> hd()
          name = token |> String.split(".") |> List.last() |> String.upcase()

          group =
            if String.contains?(token, "."),
              do: token |> String.split(".") |> Enum.drop(-1) |> Enum.join("."),
              else: nil

          Map.merge(line, %{head: head, value: content, name: name, group: group})
        end)

      {:ok, parsed}
    else
      {:error, :invalid_document}
    end
  catch
    _ -> {:error, :invalid_document}
  end

  defp tokenize(_), do: {:error, :invalid_document}

  defp split_content(logical), do: split_content(logical, 0, false)

  defp split_content(logical, index, quoted) when index < byte_size(logical) do
    case :binary.at(logical, index) do
      ?" ->
        split_content(logical, index + 1, not quoted)

      ?: when not quoted ->
        {binary_part(logical, 0, index),
         binary_part(logical, index + 1, byte_size(logical) - index - 1)}

      _ ->
        split_content(logical, index + 1, quoted)
    end
  end

  defp split_content(_, _, _), do: throw(:invalid_document)

  defp replace_property(lines, name, content) do
    existing = Enum.find(lines, &(&1.name == name))
    replacement = make_line(if(existing, do: existing.head, else: name), content)
    replace_named(lines, name, [replacement])
  end

  defp replace_named(lines, name, replacements) do
    {before, rest} = Enum.split_while(lines, &(&1.name != name))

    case rest do
      [] ->
        {body, ending} = Enum.split(lines, -1)
        body ++ replacements ++ ending

      _ ->
        before ++ replacements ++ Enum.reject(rest, &(&1.name == name))
    end
  end

  defp replace_values(lines, name, desired, field) when is_list(desired) do
    existing =
      lines
      |> Enum.filter(&(&1.name == name))
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        Map.put(
          line,
          :property_id,
          if(line.group,
            do: line.group <> "." <> name,
            else: name <> ":" <> Integer.to_string(index)
          )
        )
      end)

    {replacement, unused} =
      Enum.map_reduce(desired, existing, fn item, available ->
        encoded = array_value(item, field)
        label = map_value(item, "label", "")

        property_id = Map.get(item, "property_id")

        exact =
          Enum.find(available, fn line -> line.value == encoded and type_label(line) == label end)

        match =
          if property_id,
            do: Enum.find(available, &(&1.property_id == property_id)) || exact,
            else: exact

        if match do
          replacement =
            if match.value == encoded and type_label(match) == label do
              match
            else
              head =
                if type_label(match) == label,
                  do: match.head,
                  else: replace_type(match.head, label)

              make_line(head, encoded) |> Map.put(:group, match.group)
            end

          {replacement, List.delete(available, match)}
        else
          {make_line(
             name <> if(label == "", do: "", else: ";TYPE=" <> safe_type(label)),
             encoded
           ), available}
        end
      end)

    groups = unused |> Enum.map(& &1.group) |> Enum.reject(&is_nil/1) |> MapSet.new()
    kept_groups = replacement |> Enum.map(& &1.group) |> MapSet.new()

    lines =
      Enum.reject(lines, fn line ->
        line.name == "X-ABLABEL" and MapSet.member?(groups, line.group) and
          not MapSet.member?(kept_groups, line.group) and
          not Enum.any?(lines, &(&1.group == line.group and &1.name not in [name, "X-ABLABEL"]))
      end)

    replace_named(lines, name, replacement)
  end

  defp replace_type(head, label) do
    [name | params] = ContentLine.split(head, ";")

    params =
      Enum.reject(params, fn param -> String.starts_with?(String.upcase(param), "TYPE=") end)

    params = if label == "", do: params, else: params ++ ["TYPE=" <> safe_type(label)]
    Enum.join([name | params], ";")
  end

  defp type_label(line) do
    case ContentLine.parse(line.logical <> "\r\n") do
      {:ok, [prop]} -> Map.get(prop.params, "TYPE", "")
      _ -> ""
    end
  end

  defp array_value(item, :addresses),
    do:
      Enum.map_join(
        ~w(po_box extended_address street locality region postal_code country),
        ";",
        &escape(map_value(item, &1, ""))
      )

  defp array_value(item, _), do: escape(map_value(item, "value", ""))

  defp safe_type(label) do
    if Regex.match?(~r/\A[A-Za-z0-9,_ -]{0,128}\z/, label),
      do: label,
      else: throw(:invalid_document)
  end

  defp event_ranges(lines) do
    {_, _, ranges} =
      Enum.reduce(Enum.with_index(lines), {[], nil, []}, fn {line, index},
                                                            {stack, start, ranges} ->
        cond do
          line.name == "BEGIN" ->
            if length(stack) >= 16, do: throw(:invalid_document)
            if line.value == "VEVENT" and stack != ["VCALENDAR"], do: throw(:invalid_document)
            {[line.value | stack], if(line.value == "VEVENT", do: index, else: start), ranges}

          line.name == "END" ->
            case stack do
              [name | tail] when name == line.value ->
                {tail, if(name == "VEVENT", do: nil, else: start),
                 if(name == "VEVENT", do: [{start, index} | ranges], else: ranges)}

              _ ->
                throw(:invalid_document)
            end

          true ->
            {stack, start, ranges}
        end
      end)

    {:ok, Enum.reverse(ranges)}
  catch
    _ -> {:error, :invalid_document}
  end

  defp event_range(lines, uid, recurrence_id) do
    with {:ok, ranges} <- event_ranges(lines) do
      case Enum.find(ranges, fn {first, last} ->
             props = Enum.slice(lines, first..last)

             property(props, "UID") == uid and
               property(props, "RECURRENCE-ID", "") == recurrence_id
           end) do
        {first, last} -> {:ok, first, last}
        nil -> {:error, :event_not_found}
      end
    end
  end

  defp property(lines, name, default \\ nil),
    do: Enum.find_value(lines, default, fn line -> if line.name == name, do: line.value end)

  defp top_property(lines, name) do
    Enum.reduce_while(lines, 0, fn line, depth ->
      cond do
        line.name == "BEGIN" -> {:cont, depth + 1}
        line.name == "END" -> {:cont, depth - 1}
        depth == 1 and line.name == name -> {:halt, line}
        true -> {:cont, depth}
      end
    end)
    |> case do
      line when is_map(line) -> line
      _ -> nil
    end
  end

  defp replace_top_property(lines, name, head, content) do
    {result, _, found} =
      Enum.reduce(lines, {[], 0, false}, fn line, {acc, depth, found} ->
        cond do
          line.name == "BEGIN" ->
            {[line | acc], depth + 1, found}

          line.name == "END" and depth == 1 ->
            additions = if found, do: [line | acc], else: [line, make_line(head, content) | acc]
            {additions, depth - 1, true}

          line.name == "END" ->
            {[line | acc], depth - 1, found}

          depth == 1 and line.name == name ->
            {if(found, do: acc, else: [make_line(head, content) | acc]), depth, true}

          true ->
            {[line | acc], depth, found}
        end
      end)

    if found, do: Enum.reverse(result), else: throw(:invalid_document)
  end

  defp remove_top_property(lines, name) do
    {result, _} =
      Enum.reduce(lines, {[], 0}, fn line, {acc, depth} ->
        next =
          cond do
            line.name == "BEGIN" -> depth + 1
            line.name == "END" -> depth - 1
            true -> depth
          end

        {if(depth == 1 and line.name == name, do: acc, else: [line | acc]), next}
      end)

    Enum.reverse(result)
  end

  defp time_header(name, attrs, base, existing) do
    header =
      cond do
        value(attrs, :all_day, base.all_day) ->
          name <> ";VALUE=DATE"

        value(attrs, :timezone, base.timezone) in [nil, "", "Etc/UTC", "UTC"] ->
          name

        true ->
          zone = value(attrs, :timezone, base.timezone)

          if String.contains?(zone, ["\r", "\n", ";", ":", "\"", "\\"]),
            do: throw(:invalid_document)

          name <> ";TZID=" <> zone
      end

    params = if existing, do: existing.head |> ContentLine.split(";") |> Enum.drop(1), else: []

    extra =
      Enum.reject(params, fn param ->
        String.starts_with?(String.upcase(param), ["TZID=", "VALUE="])
      end)

    Enum.join([header | extra], ";")
  end

  defp make_line(head, content) do
    logical = head <> ":" <> content

    %{
      raw: fold(logical),
      logical: logical,
      head: head,
      value: content,
      name:
        head |> String.split(";") |> hd() |> String.split(".") |> List.last() |> String.upcase(),
      group: nil
    }
  end

  defp fold(line), do: fold(String.codepoints(line), "", [], 75)

  defp fold([], current, acc, _),
    do: Enum.reverse([current <> "\r\n" | acc]) |> IO.iodata_to_binary()

  defp fold([point | tail], current, acc, limit) do
    if byte_size(current) + byte_size(point) > limit do
      fold([point | tail], " ", [current <> "\r\n" | acc], 75)
    else
      fold(tail, current <> point, acc, limit)
    end
  end

  defp escape(nil), do: ""

  defp escape(text),
    do:
      text
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.replace("\n", "\\n")
      |> String.replace(";", "\\;")
      |> String.replace(",", "\\,")

  defp render(lines), do: Enum.map_join(lines, & &1.raw)

  defp value(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))

  defp map_value(map, key, default),
    do: Map.get(map, key, Map.get(map, existing_atom(key), default))

  defp existing_atom(key), do: String.to_existing_atom(key)
end

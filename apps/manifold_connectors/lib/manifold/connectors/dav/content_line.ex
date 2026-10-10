defmodule Manifold.Connectors.DAV.ContentLine do
  @moduledoc false
  def parse(raw) when is_binary(raw) and byte_size(raw) <= 2 * 1024 * 1024 do
    if String.valid?(raw) do
      lines =
        raw
        |> String.replace("\r\n", "\n")
        |> String.replace(~r/\n[ \t]/, "")
        |> String.split("\n", trim: true)

      if length(lines) <= 20_000, do: parse_lines(lines), else: {:error, :resource_limit}
    else
      {:error, :invalid_text}
    end
  end

  def parse(_), do: {:error, :resource_limit}

  defp parse_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case split(line, ":", 2) do
        [head, value] ->
          [name | parameters] = split(head, ";")

          params =
            Enum.reduce(parameters, %{}, fn param, map ->
              case String.split(param, "=", parts: 2) do
                [key, val] -> Map.put(map, String.upcase(key), String.trim(val, "\""))
                [val] -> Map.put(map, "TYPE", val)
              end
            end)

          property = name |> String.split(".") |> List.last() |> String.upcase()

          {:cont,
           {:ok, [%{name: property, original_name: name, params: params, value: value} | acc]}}

        _ ->
          {:halt, {:error, :invalid_content_line}}
      end
    end)
    |> case do
      {:ok, props} -> {:ok, Enum.reverse(props)}
      error -> error
    end
  end

  def split(value, delimiter, parts \\ :infinity) do
    {fields, current, _, _} =
      Enum.reduce(String.graphemes(value), {[], "", false, false}, fn char,
                                                                      {fields, current, quoted,
                                                                       escaped} ->
        cond do
          escaped ->
            {fields, current <> char, quoted, false}

          char == "\\" ->
            {fields, current <> char, quoted, true}

          char == "\"" ->
            {fields, current <> char, not quoted, false}

          char == delimiter and not quoted and (parts == :infinity or length(fields) < parts - 1) ->
            {[current | fields], "", quoted, false}

          true ->
            {fields, current <> char, quoted, false}
        end
      end)

    Enum.reverse([current | fields])
  end

  def unescape(value),
    do:
      Regex.replace(~r/\\([nN,;\\])/, value, fn _, char ->
        if char in ["n", "N"], do: "\n", else: char
      end)

  def all(props, name), do: Enum.filter(props, &(&1.name == name))

  def first(props, name, default \\ nil) do
    case Enum.find(props, &(&1.name == name)) do
      nil -> default
      prop -> prop.value
    end
  end
end

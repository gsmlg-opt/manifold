defmodule Manifold.Connectors.DAV.VCard do
  @moduledoc false
  alias Manifold.Connectors.DAV.ContentLine, as: Line

  def parse(raw) do
    with {:ok, props} <- Line.parse(raw),
         true <- match?([%{name: "BEGIN", value: "VCARD"} | _], props),
         %{name: "END", value: "VCARD"} <- List.last(props),
         true <- length(Line.all(props, "BEGIN")) == 1 and length(Line.all(props, "END")) == 1,
         version when version in ["3.0", "4.0"] <- Line.first(props, "VERSION"),
         uid when is_binary(uid) and uid != "" <- Line.first(props, "UID") do
      names = Line.split(Line.first(props, "N", ""), ";") |> Enum.map(&Line.unescape/1)
      family = Enum.at(names, 0, "")
      given = Enum.at(names, 1, "")
      name = Line.first(props, "FN", String.trim(given <> " " <> family)) |> Line.unescape()

      if name == "",
        do: {:error, :invalid_vcard},
        else:
          {:ok,
           %{
             uid: uid,
             raw: raw,
             full_name: name,
             given_name: given,
             family_name: family,
             organization: text(props, "ORG"),
             notes: text(props, "NOTE"),
             emails: values(props, "EMAIL"),
             phones: values(props, "TEL"),
             addresses:
               Line.all(props, "ADR")
               |> Enum.with_index()
               |> Enum.map(fn {prop, index} ->
                 address(prop) |> Map.put("property_id", property_id(prop, index))
               end)
           }}
    else
      _ -> {:error, :invalid_vcard}
    end
  end

  defp text(props, name), do: Line.first(props, name, "") |> Line.unescape()

  defp values(props, name) do
    Line.all(props, name)
    |> Enum.with_index()
    |> Enum.map(fn {prop, index} ->
      %{
        "value" => Line.unescape(prop.value),
        "label" => Map.get(prop.params, "TYPE", ""),
        "property_id" => property_id(prop, index)
      }
    end)
  end

  defp property_id(prop, index) do
    if String.contains?(prop.original_name, "."),
      do:
        (prop.original_name |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")) <>
          "." <> prop.name,
      else: prop.name <> ":" <> Integer.to_string(index)
  end

  defp address(prop) do
    parts = Line.split(prop.value, ";") |> Enum.map(&Line.unescape/1)

    Map.new(
      Enum.zip(
        ["po_box", "extended_address", "street", "locality", "region", "postal_code", "country"],
        Enum.map(0..6, &Enum.at(parts, &1, ""))
      )
    )
    |> Map.put("label", Map.get(prop.params, "TYPE", ""))
    |> Map.put("value", Enum.reject(parts, &(&1 == "")) |> Enum.join(", "))
  end
end

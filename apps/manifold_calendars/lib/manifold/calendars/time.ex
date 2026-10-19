defmodule Manifold.Calendars.Time do
  @moduledoc """
  iCalendar DATE and DATE-TIME interpretation for local calendar queries.

  DATE values remain dates. Floating times use the viewing zone; TZID times
  retain their source zone. Ambiguous and missing local times follow RFC 5545
  section 3.3.5 (first occurrence and the offset before the gap, respectively).
  """

  @database Tzdata.TimeZoneDatabase

  @spec parse(String.t(), String.t() | nil, String.t()) ::
          {:ok, Date.t() | DateTime.t()} | {:error, term()}
  def parse(value, source_timezone \\ nil, viewing_timezone \\ "Etc/UTC")

  def parse(value, source_timezone, viewing_timezone) when is_binary(value) do
    {value, source_timezone} = property_value(value, source_timezone)

    case Regex.run(~r/\A(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})(Z)?)?\z/, value) do
      [_, year, month, day] ->
        Date.new(number(year), number(month), number(day))

      [_, year, month, day, hour, minute, second | suffix] ->
        source_zone =
          if suffix == ["Z"], do: "Etc/UTC", else: zone(source_timezone, viewing_timezone)

        with {:ok, date} <- Date.new(number(year), number(month), number(day)),
             {:ok, time} <- Time.new(number(hour), number(minute), number(second)),
             {:ok, datetime} <- from_naive(NaiveDateTime.new!(date, time), source_zone),
             {:ok, viewed} <-
               DateTime.shift_zone(datetime, normalize_zone(viewing_timezone), @database) do
          {:ok, viewed}
        end

      _ ->
        {:error, :invalid_calendar_time}
    end
  end

  def parse(_, _, _), do: {:error, :invalid_calendar_time}

  @doc "Returns a validated, exclusive-end period in the viewing zone."
  def period(event, viewing_timezone) do
    source_timezone = Map.get(event, :timezone)

    with {:ok, start} <- parse(Map.get(event, :starts_at), source_timezone, viewing_timezone),
         {:ok, finish} <- finish(event, start, source_timezone, viewing_timezone),
         :ok <- valid_period(start, finish) do
      {:ok, %{starts_at: start, ends_at: finish, all_day: match?(%Date{}, start)}}
    end
  end

  @doc "Formats a source value without changing its wall clock or DATE semantics."
  def compact(%Date{} = date), do: Calendar.strftime(date, "%Y%m%d")

  def compact(%DateTime{} = datetime) do
    suffix = if datetime.time_zone in ["Etc/UTC", "UTC"], do: "Z", else: ""
    Calendar.strftime(datetime, "%Y%m%dT%H%M%S") <> suffix
  end

  @doc false
  def property_value(value, fallback_zone) do
    case String.split(value, ":", parts: 2) do
      [header, body] ->
        timezone =
          header
          |> String.split(";")
          |> Enum.find_value(fn parameter ->
            case String.split(parameter, "=", parts: 2) do
              ["TZID", timezone] -> String.trim(timezone, "\"")
              _ -> nil
            end
          end)

        {body, timezone || fallback_zone}

      [_] ->
        {value, fallback_zone}
    end
  end

  defp finish(event, start, source_timezone, viewing_timezone) do
    case Map.get(event, :ends_at) do
      value when value in [nil, ""] ->
        {:ok, if(match?(%Date{}, start), do: Date.add(start, 1), else: start)}

      value ->
        parse(value, source_timezone, viewing_timezone)
    end
  end

  defp valid_period(%Date{} = start, %Date{} = finish) do
    if Date.compare(finish, start) == :gt, do: :ok, else: {:error, :invalid_calendar_interval}
  end

  defp valid_period(%DateTime{} = start, %DateTime{} = finish) do
    if DateTime.compare(finish, start) != :lt, do: :ok, else: {:error, :invalid_calendar_interval}
  end

  defp valid_period(_, _), do: {:error, :mixed_calendar_time_types}

  defp from_naive(naive, timezone) do
    case DateTime.from_naive(naive, timezone, @database) do
      {:ok, datetime} ->
        {:ok, datetime}

      {:ambiguous, first, _second} ->
        {:ok, first}

      {:gap, before, _after} ->
        naive
        |> DateTime.from_naive!("Etc/UTC")
        |> DateTime.add(-(before.utc_offset + before.std_offset), :second)
        |> DateTime.shift_zone(timezone, @database)

      {:error, _} = error ->
        error
    end
  end

  defp number(value), do: String.to_integer(value)
  defp zone(value, fallback) when value in [nil, ""], do: normalize_zone(fallback)
  defp zone(value, _fallback), do: normalize_zone(value)
  defp normalize_zone("UTC"), do: "Etc/UTC"
  defp normalize_zone(value), do: value
end

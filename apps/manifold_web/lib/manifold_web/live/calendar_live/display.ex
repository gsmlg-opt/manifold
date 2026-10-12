defmodule ManifoldWeb.CalendarLive.Display do
  @moduledoc false

  def date(value) when is_binary(value) do
    case value do
      <<year::binary-size(4), month::binary-size(2), day::binary-size(2), _rest::binary>> ->
        Date.from_iso8601("#{year}-#{month}-#{day}") |> valid_date()

      _ ->
        nil
    end
  end

  def date(_), do: nil
  defp valid_date({:ok, date}), do: date
  defp valid_date(_), do: nil

  def month(%Date{} = date), do: %{date | day: 1}

  def shift_month(date, direction) do
    anchor = month(date)
    month(Date.add(anchor, if(direction > 0, do: Date.days_in_month(anchor), else: -1)))
  end

  def month_days(date) do
    anchor = month(date)
    first = Date.add(anchor, -(Date.day_of_week(anchor) - 1))
    Enum.map(0..41, &Date.add(first, &1))
  end

  def last_day(event) do
    first = date(event.starts_at)
    finish = date(event.ends_at)

    cond do
      is_nil(finish) -> first
      event.all_day or midnight?(event.ends_at) -> Date.add(finish, -1)
      true -> finish
    end
  end

  def on_day?(event, day) do
    first = date(event.starts_at)
    last = last_day(event)
    first && last && Date.compare(first, day) != :gt && Date.compare(last, day) != :lt
  end

  def agenda(events, anchor) do
    first = month(anchor)
    until = shift_month(first, 1)

    events
    |> Enum.filter(fn event ->
      start = date(event.starts_at)
      finish = last_day(event)
      start && finish && Date.compare(start, until) == :lt && Date.compare(finish, first) != :lt
    end)
    |> Enum.group_by(fn event ->
      start = date(event.starts_at)
      if Date.compare(start, first) == :lt, do: first, else: start
    end)
    |> Enum.sort_by(fn {date, _} -> Date.to_gregorian_days(date) end)
  end

  def clock(%{all_day: true}), do: "All day"
  def clock(%{starts_at: value}), do: clock(value)

  def clock(
        <<_date::binary-size(8), "T", hour::binary-size(2), minute::binary-size(2),
          _rest::binary>>
      ),
      do: hour <> ":" <> minute

  def clock(_), do: "All day"

  def recurring?(event), do: event.recurrence_rules != [] or event.recurrence_id not in [nil, ""]

  defp midnight?(value) when is_binary(value), do: String.slice(value, 8, 7) == "T000000"
  defp midnight?(_), do: false
end

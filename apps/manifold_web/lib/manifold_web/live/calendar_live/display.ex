defmodule ManifoldWeb.CalendarLive.Display do
  @moduledoc false
  alias Manifold.Calendars.Time, as: CalendarTime

  def date(value, timezone \\ "Etc/UTC")
  def date(%Date{} = date, _), do: date
  def date(%DateTime{} = datetime, _), do: DateTime.to_date(datetime)

  def date(value, timezone) when is_binary(value) do
    case CalendarTime.parse(value, nil, timezone) do
      {:ok, time} -> date(time, timezone)
      _ -> nil
    end
  end

  def date(_, _), do: nil

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

  def last_day(event, timezone \\ "Etc/UTC") do
    case period(event, timezone) do
      {:ok, %{starts_at: %Date{} = first, ends_at: %Date{} = finish}} ->
        if Date.compare(finish, first) == :gt, do: Date.add(finish, -1), else: first

      {:ok, %{starts_at: %DateTime{} = first, ends_at: %DateTime{} = finish}} ->
        if DateTime.compare(finish, first) == :gt,
          do: finish |> DateTime.add(-1, :microsecond) |> DateTime.to_date(),
          else: DateTime.to_date(first)

      _ ->
        nil
    end
  end

  def on_day?(event, day, timezone \\ "Etc/UTC") do
    with {:ok, period} <- period(event, timezone),
         first when not is_nil(first) <- date(period.starts_at),
         last when not is_nil(last) <- last_day(event, timezone) do
      Date.compare(first, day) != :gt and Date.compare(last, day) != :lt
    else
      _ -> false
    end
  end

  def agenda(occurrences, anchor) do
    first = month(anchor)
    until = shift_month(first, 1)

    occurrences
    |> Enum.filter(fn occurrence ->
      on_day?(occurrence, max_date(date(occurrence.starts_at), first)) &&
        Date.compare(date(occurrence.starts_at), until) == :lt &&
        Date.compare(last_day(occurrence), first) != :lt
    end)
    |> Enum.group_by(&max_date(date(&1.starts_at), first))
    |> Enum.sort_by(fn {date, _} -> Date.to_gregorian_days(date) end)
  end

  def clock(event, timezone \\ "Etc/UTC")
  def clock(%{all_day: true}, _), do: "All day"
  def clock(%{clock: clock}, _), do: clock

  def clock(%{starts_at: _} = event, timezone) do
    case period(event, timezone) do
      {:ok, period} -> clock(period.starts_at, timezone)
      _ -> "Invalid time"
    end
  end

  def clock(%DateTime{} = datetime, _), do: Calendar.strftime(datetime, "%H:%M")
  def clock(%Date{}, _), do: "All day"

  def clock(value, timezone) when is_binary(value) do
    case CalendarTime.parse(value, nil, timezone) do
      {:ok, time} -> clock(time, timezone)
      _ -> "Invalid time"
    end
  end

  def clock(_, _), do: "Invalid time"

  def recurring?(event),
    do:
      Map.get(event, :recurrence_rules, []) != [] or Map.get(event, :recurrence_dates, []) != [] or
        Map.get(event, :recurrence_id) not in [nil, ""]

  defp period(%{starts_at: %DateTime{}} = occurrence, _), do: {:ok, occurrence}
  defp period(%{starts_at: %Date{}} = occurrence, _), do: {:ok, occurrence}
  defp period(event, timezone), do: CalendarTime.period(event, timezone)
  defp max_date(nil, right), do: right
  defp max_date(left, right), do: if(Date.compare(left, right) == :lt, do: right, else: left)
end

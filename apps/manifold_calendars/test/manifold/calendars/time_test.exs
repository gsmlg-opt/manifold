defmodule Manifold.Calendars.TimeTest do
  use ExUnit.Case, async: true

  alias Manifold.Calendars.Time, as: CalendarTime

  test "DATE retains its calendar day in every viewing zone" do
    assert {:ok, ~D[2026-10-19]} = CalendarTime.parse("20261019", nil, "America/Los_Angeles")
  end

  test "UTC converts into the viewing date and clock" do
    assert {:ok, value} = CalendarTime.parse("20261019T233000Z", nil, "Asia/Shanghai")
    assert DateTime.to_date(value) == ~D[2026-10-20]
    assert DateTime.to_time(value) == ~T[07:30:00]
  end

  test "floating time follows the viewer's wall clock" do
    assert {:ok, shanghai} = CalendarTime.parse("20261019T093000", nil, "Asia/Shanghai")
    assert {:ok, new_york} = CalendarTime.parse("20261019T093000", nil, "America/New_York")
    assert shanghai.hour == 9
    assert new_york.hour == 9
    assert DateTime.compare(shanghai, new_york) == :lt
  end

  test "TZID uses the source offset including DST" do
    assert {:ok, summer} = CalendarTime.parse("20260719T090000", "America/New_York", "Etc/UTC")
    assert summer == ~U[2026-07-19 13:00:00Z]
    assert {:ok, winter} = CalendarTime.parse("20261219T090000", "America/New_York", "Etc/UTC")
    assert winter == ~U[2026-12-19 14:00:00Z]
  end

  test "ambiguous local time means the first occurrence and nonexistent time uses pre-gap offset" do
    assert {:ok, ~U[2026-11-01 05:30:00Z]} =
             CalendarTime.parse("20261101T013000", "America/New_York", "Etc/UTC")

    assert {:ok, ~U[2026-03-08 07:30:00Z]} =
             CalendarTime.parse("20260308T023000", "America/New_York", "Etc/UTC")
  end

  test "invalid dates and unknown zones are explicit errors" do
    assert {:error, _} = CalendarTime.parse("20260230", nil, "Etc/UTC")
    assert {:error, _} = CalendarTime.parse("20261019T090000", "Unknown/Zone", "Etc/UTC")
    assert {:error, _} = CalendarTime.parse("20261019T090000Z", nil, "Unknown/Zone")
  end

  test "missing DATE end defaults to the following day and timed end defaults to start" do
    assert {:ok, %{starts_at: ~D[2026-10-19], ends_at: ~D[2026-10-20], all_day: true}} =
             CalendarTime.period(%{starts_at: "20261019", ends_at: nil, timezone: nil}, "Etc/UTC")

    assert {:ok, %{starts_at: start, ends_at: finish, all_day: false}} =
             CalendarTime.period(%{starts_at: "20261019T090000Z", ends_at: nil}, "Etc/UTC")

    assert start == finish
  end

  test "period rejects mixed time types and reversed end" do
    assert {:error, _} =
             CalendarTime.period(%{starts_at: "20261019", ends_at: "20261020T090000Z"}, "Etc/UTC")

    assert {:error, _} =
             CalendarTime.period(
               %{starts_at: "20261019T090000Z", ends_at: "20261019T080000Z"},
               "Etc/UTC"
             )
  end

  test "compact preserves DATE and datetime wall values" do
    assert CalendarTime.compact(~D[2026-10-19]) == "20261019"
    assert CalendarTime.compact(~U[2026-10-19 09:30:00Z]) == "20261019T093000Z"
  end
end

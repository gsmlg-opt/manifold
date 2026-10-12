defmodule ManifoldWeb.CalendarDisplayTest do
  use ExUnit.Case, async: true
  alias ManifoldWeb.CalendarLive.Display

  test "month navigation handles year and leap-day boundaries" do
    assert Display.shift_month(~D[2026-12-31], 1) == ~D[2027-01-01]
    assert Display.shift_month(~D[2027-01-31], -1) == ~D[2026-12-01]
    assert Display.shift_month(~D[2024-03-31], -1) == ~D[2024-02-01]
    days = Display.month_days(~D[2024-02-29])
    assert length(days) == 42
    assert hd(days) == ~D[2024-01-29]
    assert List.last(days) == ~D[2024-03-10]
  end

  test "stored dates keep wall times and exclusive all-day and midnight ends" do
    event = %{starts_at: "20261030", ends_at: "20261102", all_day: true}
    assert Display.on_day?(event, ~D[2026-11-01])
    refute Display.on_day?(event, ~D[2026-11-02])
    event = %{starts_at: "20261030T220000Z", ends_at: "20261102T000000Z", all_day: false}
    assert Display.on_day?(event, ~D[2026-11-01])
    refute Display.on_day?(event, ~D[2026-11-02])
    assert Display.clock(event) == "22:00"
    assert Display.date("20261399") == nil
    assert Display.date(nil) == nil
  end
end

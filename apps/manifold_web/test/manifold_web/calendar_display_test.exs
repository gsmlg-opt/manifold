defmodule ManifoldWeb.CalendarDisplayTest do
  use ExUnit.Case, async: true
  alias ManifoldWeb.CalendarLive.Display

  test "month navigation handles year and leap-day boundaries" do
    assert Display.shift_month(~D[2026-12-31], 1) == ~D[2027-01-01]
    assert Display.shift_month(~D[2024-03-31], -1) == ~D[2024-02-01]
    days = Display.month_days(~D[2024-02-29])
    assert length(days) == 42
    assert hd(days) == ~D[2024-01-29]
    assert List.last(days) == ~D[2024-03-10]
  end

  test "viewed times cross dates and exclusive midnight ends do not occupy the next day" do
    event = %{starts_at: "20261019T233000Z", ends_at: "20261020T003000Z", all_day: false}
    assert Display.date(event.starts_at, "Asia/Shanghai") == ~D[2026-10-20]
    assert Display.clock(event, "Asia/Shanghai") == "07:30"
    assert Display.on_day?(event, ~D[2026-10-20], "Asia/Shanghai")
    refute Display.on_day?(event, ~D[2026-10-19], "Asia/Shanghai")
    midnight = %{starts_at: "20261019T220000Z", ends_at: "20261020T000000Z", all_day: false}
    refute Display.on_day?(midnight, ~D[2026-10-20])
    assert Display.date("20261399") == nil
  end

  test "all-day events retain date semantics in every viewing zone" do
    event = %{starts_at: "20261030", ends_at: "20261102", all_day: true}
    assert Display.on_day?(event, ~D[2026-11-01], "America/Los_Angeles")
    refute Display.on_day?(event, ~D[2026-11-02], "Asia/Shanghai")
    assert Display.clock(event) == "All day"
  end
end

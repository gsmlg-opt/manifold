defmodule Manifold.Core.TimeZoneStartupTest do
  use ExUnit.Case, async: true

  test "starting core initializes the global time-zone database before its consumers" do
    probe = """
    Application.put_env(:elixir, :time_zone_database, #{inspect(Calendar.get_time_zone_database())})
    Application.put_env(:tzdata, :autoupdate, :disabled)
    {:ok, started} = Application.ensure_all_started(:manifold_core)

    now = ~U[2026-01-01 00:00:00Z]
    ~U[2026-01-01 00:00:30Z] = DateTime.add(now, 30)
    {:ok, %DateTime{hour: 8, time_zone: "Asia/Shanghai"}} =
      DateTime.shift_zone(now, "Asia/Shanghai")

    tzdata_index = Enum.find_index(started, &(&1 == :tzdata))
    core_index = Enum.find_index(started, &(&1 == :manifold_core))
    true = is_integer(tzdata_index) and tzdata_index < core_index

    apps = Enum.map(Application.started_applications(), &elem(&1, 0))
    false = :manifold_data in apps or :manifold_calendars in apps
    IO.puts("TIME_ZONE_STARTUP_PASS")
    """

    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])

    {output, status} =
      System.cmd(
        System.find_executable("elixir"),
        ["--erl", "+S 2:2 +SDcpu 1 +SDio 1"] ++ paths ++ ["-e", probe],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "TIME_ZONE_STARTUP_PASS"
  end
end

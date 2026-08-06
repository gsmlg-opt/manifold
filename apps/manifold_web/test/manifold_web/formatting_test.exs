defmodule ManifoldWeb.FormattingTest do
  use ExUnit.Case, async: true

  alias ManifoldWeb.Formatting

  test "datetime formats as YYYY-MM-DD HH:MM" do
    assert Formatting.datetime(~U[2026-08-06 08:15:30Z]) == "2026-08-06 08:15"
    assert Formatting.datetime(~N[2025-12-31 23:59:01]) == "2025-12-31 23:59"
    assert Formatting.datetime(nil) == ""
  end

  test "datetime_utc appends UTC label" do
    assert Formatting.datetime_utc(~U[2026-01-02 03:04:05Z]) == "2026-01-02 03:04 UTC"
    assert Formatting.datetime_utc(nil) == ""
  end

  test "datetime_iso parses ISO-8601 timestamps" do
    assert Formatting.datetime_iso("2026-08-06T16:20:00.123456Z") == "2026-08-06 16:20"
    assert Formatting.datetime_iso("not-a-date") == "not-a-date"
    assert Formatting.datetime_iso(nil) == ""
  end
end

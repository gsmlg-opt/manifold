defmodule ManifoldWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import ManifoldWeb.CoreComponents

  test "datetime renders mf-datetime with ISO attribute and UTC fallback text" do
    html =
      render_component(&datetime/1,
        value: ~U[2026-08-06 14:46:00.000000Z],
        format: "datetime"
      )

    assert html =~ ~s(datetime="2026-08-06T14:46:00.000000Z")
    assert html =~ ~s(format="datetime")
    assert html =~ "2026-08-06 14:46"
    assert html =~ "<mf-datetime"
  end

  test "datetime renders nothing for nil" do
    assert render_component(&datetime/1, value: nil) == ""
  end
end

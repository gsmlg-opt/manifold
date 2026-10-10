defmodule ManifoldWeb.LayoutsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ManifoldWeb.Layouts

  @info %{
    version: "0.6.0",
    environment: :prod,
    git_ref: "v0.6.0",
    git_sha: "0123456789abcdef",
    built_at: "2026-10-10T01:00:00Z",
    released_at: "2026-10-10T02:00:00Z"
  }

  test "only development builds have the dev suffix" do
    for {environment, label} <- [dev: "v0.6.0-dev", test: "v0.6.0", prod: "v0.6.0"] do
      html =
        render_component(&Layouts.appbar_version/1, info: %{@info | environment: environment})

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("button")
             |> LazyHTML.text()
             |> String.trim() == label
    end
  end

  test "version trigger is associated with full build and release details" do
    html = render_component(&Layouts.appbar_version/1, info: @info) |> LazyHTML.from_fragment()
    trigger = LazyHTML.query(html, "button#appbar-version[type='button']")
    tooltip = LazyHTML.query(html, "#appbar-version-tooltip[role='tooltip'][popover='hint']")

    assert LazyHTML.attribute(trigger, "aria-describedby") == ["appbar-version-tooltip"]
    assert LazyHTML.attribute(trigger, "interestfor") == ["appbar-version-tooltip"]

    for detail <- [
          "Version: 0.6.0",
          "Environment: prod",
          "Git ref: v0.6.0",
          "Git commit: 0123456789abcdef",
          "Release time: 2026-10-10T02:00:00Z",
          "Build time: 2026-10-10T01:00:00Z"
        ] do
      assert LazyHTML.text(tooltip) =~ detail
    end
  end

  test "missing source or release information is shown honestly" do
    html =
      render_component(&Layouts.appbar_version/1,
        info: %{@info | git_ref: nil, git_sha: nil, released_at: nil}
      )

    assert html =~ "Git ref: Not recorded"
    assert html =~ "Git commit: Not recorded"
    assert html =~ "Release time: Not recorded"
    assert html =~ "Build time: 2026-10-10T01:00:00Z"
  end

  test "both appbars show the running version next to the brand" do
    for layout <- [&Layouts.app/1, &Layouts.settings/1] do
      html =
        render_component(layout, flash: %{}, inner_content: "", settings_section: :general)
        |> LazyHTML.from_fragment()

      assert html
             |> LazyHTML.query("#app-appbar > a.appbar-brand + button#appbar-version")
             |> LazyHTML.text()
             |> String.trim() == "v#{ManifoldWeb.BuildInfo.current().version}"
    end
  end
end

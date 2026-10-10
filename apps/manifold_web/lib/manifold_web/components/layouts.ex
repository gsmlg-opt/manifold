defmodule ManifoldWeb.Layouts do
  use ManifoldWeb, :html

  import ManifoldWeb.SettingsComponents

  embed_templates("layouts/*")

  attr :info, :map, default: nil

  def appbar_version(assigns) do
    info = assigns.info || ManifoldWeb.BuildInfo.current()
    version = "v#{info.version}" <> if(info.environment == :dev, do: "-dev", else: "")

    details =
      Enum.map_join(
        [
          {"Version", info.version},
          {"Environment", info.environment},
          {"Git ref", info.git_ref},
          {"Git commit", info.git_sha},
          {"Release time", info.released_at},
          {"Build time", info.built_at}
        ],
        "\n",
        fn {label, value} -> "#{label}: #{value || "Not recorded"}" end
      )

    assigns = assign(assigns, version: version, details: details)

    ~H"""
    <.dm_tooltip
      :let={trigger_attrs}
      id="appbar-version"
      content={@details}
      position="bottom"
      class="appbar-version-tooltip"
    >
      <button
        id="appbar-version"
        type="button"
        class="appbar-version rounded-full"
        aria-label={"Version details: #{@version}"}
        {trigger_attrs}
      >
        <.dm_badge variant="primary" soft pill>{@version}</.dm_badge>
      </button>
    </.dm_tooltip>
    """
  end
end

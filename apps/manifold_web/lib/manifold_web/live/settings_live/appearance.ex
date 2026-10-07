defmodule ManifoldWeb.SettingsLive.Appearance do
  use ManifoldWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Appearance")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>Appearance</h1>
          <p class="settings-intro">Customize how Manifold looks on this browser.</p>
        </div>
      </div>
      <div class="flex flex-col gap-4">
        <div>
          <h2 class="text-lg font-semibold">Theme</h2>
          <p class="settings-secondary">
            Follow your system settings or choose a light or dark appearance.
            Your choice is saved in this browser.
          </p>
        </div>
        <.dm_segment_control
          id="appearance-theme-switcher"
          class="appearance-theme-control"
          label="Theme"
          phx-hook="ThemePreference"
          phx-update="ignore"
        >
          <:item value="default">System</:item>
          <:item value="sunshine">Light</:item>
          <:item value="moonlight">Dark</:item>
        </.dm_segment_control>
      </div>
    </section>
    """
  end
end

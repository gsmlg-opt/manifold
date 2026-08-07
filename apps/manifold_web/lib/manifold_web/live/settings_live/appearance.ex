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
          <p class="settings-intro">Coming soon</p>
        </div>
      </div>
    </section>
    """
  end
end

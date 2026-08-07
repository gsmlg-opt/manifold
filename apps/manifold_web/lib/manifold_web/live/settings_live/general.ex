defmodule ManifoldWeb.SettingsLive.General do
  use ManifoldWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "General")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>General</h1>
          <p class="settings-intro">Coming soon</p>
        </div>
      </div>
    </section>
    """
  end
end

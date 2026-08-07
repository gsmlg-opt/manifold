defmodule ManifoldWeb.SettingsComponents do
  @moduledoc false

  use ManifoldWeb, :html

  attr(:current, :atom, required: true, values: [:general, :accounts, :appearance])

  def settings_nav(assigns) do
    ~H"""
    <aside class="settings-nav-aside" aria-label="Settings">
      <p class="settings-nav-title">Settings</p>
      <nav id="settings-nav" class="settings-nav-list" data-current={@current}>
        <.link
          navigate={~p"/settings/general"}
          class={["settings-nav-link", @current == :general && "is-current"]}
        >
          <.dm_mdi name="cog-outline" class="settings-nav-icon" />
          <span>General</span>
        </.link>
        <.link
          navigate={~p"/settings/accounts"}
          class={["settings-nav-link", @current == :accounts && "is-current"]}
        >
          <.dm_mdi name="account-multiple-outline" class="settings-nav-icon" />
          <span>Accounts</span>
        </.link>
        <.link
          navigate={~p"/settings/appearance"}
          class={["settings-nav-link", @current == :appearance && "is-current"]}
        >
          <.dm_mdi name="palette-outline" class="settings-nav-icon" />
          <span>Appearance</span>
        </.link>
      </nav>
    </aside>
    """
  end
end

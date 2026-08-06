defmodule ManifoldWeb.Hooks.Theme do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  @themes ~w(default sunshine moonlight)

  def on_mount(:default, _params, _session, socket) do
    # Do not assign a concrete theme here. Passing theme="default" (or any
    # server value) into <.dm_theme_switcher> makes the ThemeSwitcher hook
    # overwrite localStorage on mount/navigation. Persistence is client-side.
    socket = attach_hook(socket, :theme_changed, :handle_event, &handle_event/3)

    {:cont, socket}
  end

  defp handle_event("theme_changed", %{"theme" => theme}, socket) when theme in @themes do
    {:halt, assign(socket, :theme, theme)}
  end

  defp handle_event("theme_changed", _params, socket) do
    {:halt, socket}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}
end

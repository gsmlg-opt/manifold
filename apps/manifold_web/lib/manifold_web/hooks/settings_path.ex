defmodule ManifoldWeb.Hooks.SettingsPath do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    socket =
      socket
      |> assign(:settings_section, :general)
      |> attach_hook(:settings_section, :handle_params, fn _params, url, socket ->
        {:cont, assign(socket, :settings_section, section_from_path(URI.parse(url).path))}
      end)

    {:cont, socket}
  end

  defp section_from_path("/settings/general"), do: :general
  defp section_from_path("/settings/appearance"), do: :appearance
  defp section_from_path("/settings/oauth" <> _), do: :oauth
  defp section_from_path("/settings/accounts" <> _), do: :accounts
  defp section_from_path(_), do: :general
end

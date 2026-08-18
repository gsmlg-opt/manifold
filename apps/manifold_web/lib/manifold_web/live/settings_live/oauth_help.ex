defmodule ManifoldWeb.SettingsLive.OAuthHelp do
  use ManifoldWeb, :live_view

  alias Manifold.Connectors.OAuthProviderCatalog

  @impl Phoenix.LiveView
  def mount(%{"provider" => provider}, _session, socket) do
    case OAuthProviderCatalog.fetch(provider) do
      {:ok, definition} ->
        {:ok,
         assign(socket,
           page_title: "#{definition.name} OAuth help",
           definition: definition,
           callback_uri:
             ManifoldWeb.Endpoint.url()
             |> URI.merge(definition.callback_path)
             |> URI.to_string()
         )}

      {:error, _error} ->
        {:ok,
         socket
         |> put_flash(:error, "OAuth provider help is unavailable.")
         |> push_navigate(to: ~p"/settings/oauth")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>{@definition.name} OAuth help</h1>
          <p class="settings-intro">
            Register this exact callback URI with the provider.
          </p>
        </div>
        <div class="settings-heading-actions">
          <.link navigate={~p"/settings/oauth"} class="settings-action">
            Back to OAuth settings
          </.link>
        </div>
      </div>

      <.dm_card
        id={"oauth-provider-#{@definition.key}-help"}
        variant="bordered"
        class="mailbox-setup-panel"
      >
        <:title>{@definition.name}</:title>
        <.dm_input
          id={"oauth-provider-#{@definition.key}-help-callback"}
          name={"oauth_provider_#{@definition.key}_help_callback"}
          label="Callback URI"
          value={@callback_uri}
          readonly
          helper="Copy this exact URI into the provider's OAuth application settings."
        />
      </.dm_card>
    </section>
    """
  end
end

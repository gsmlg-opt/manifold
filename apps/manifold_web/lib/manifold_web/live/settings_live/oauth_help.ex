defmodule ManifoldWeb.SettingsLive.OAuthHelp do
  use ManifoldWeb, :live_view

  alias Manifold.Connectors.OAuthProviderCatalog

  @impl Phoenix.LiveView
  def mount(%{"provider" => provider}, _session, socket) do
    case OAuthProviderCatalog.fetch(provider) do
      {:ok, definition} ->
        {:ok,
         assign(socket,
           page_title: definition.help.title,
           definition: definition,
           help: definition.help,
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
    <section aria-labelledby={"oauth-provider-#{@definition.key}-help-title"}>
      <div class="settings-heading">
        <div>
          <h1 id={"oauth-provider-#{@definition.key}-help-title"}>{@help.title}</h1>
          <p class="settings-intro">
            Follow these steps to configure {@definition.name} for Manifold.
          </p>
        </div>
        <div class="settings-heading-actions">
          <.link
            navigate={"/settings/oauth#oauth-provider-#{@definition.key}"}
            class="settings-action"
          >
            Back to {@help.configuration_title} configuration
          </.link>
        </div>
      </div>

      <.dm_card
        id={"oauth-provider-#{@definition.key}-help"}
        variant="bordered"
        shadow="sm"
        class="oauth-provider-card"
        body_class="grid gap-6"
      >
        <section aria-labelledby={"oauth-provider-#{@definition.key}-help-steps-title"}>
          <h2 id={"oauth-provider-#{@definition.key}-help-steps-title"}>Setup checklist</h2>
          <ol id={"oauth-provider-#{@definition.key}-help-steps"} class="list-decimal space-y-2 pl-6">
            <li :for={step <- @help.steps}>{step}</li>
          </ol>
        </section>

        <section aria-labelledby={"oauth-provider-#{@definition.key}-help-callback-title"}>
          <h2 id={"oauth-provider-#{@definition.key}-help-callback-title"}>Callback URI</h2>
          <p class="settings-secondary">
            Register this exact callback URI in the OAuth client.
          </p>
          <.dm_input
            id={"oauth-provider-#{@definition.key}-help-callback"}
            name={"oauth_provider_#{@definition.key}_help_callback"}
            label="Callback URI"
            value={@callback_uri}
            readonly
            helper="Copy this exact URI into the provider's OAuth application settings."
          />
        </section>

        <section aria-labelledby={"oauth-provider-#{@definition.key}-help-scopes-title"}>
          <h2 id={"oauth-provider-#{@definition.key}-help-scopes-title"}>Required scopes</h2>
          <p class="settings-secondary">Add only these scopes.</p>
          <dl class="grid gap-3">
            <div :for={scope <- @help.scopes} data-scope={scope.value}>
              <dt><code class="break-all">{scope.value}</code></dt>
              <dd class="settings-secondary">{scope.purpose}</dd>
            </div>
          </dl>
        </section>

        <section aria-labelledby={"oauth-provider-#{@definition.key}-help-notes-title"}>
          <h2 id={"oauth-provider-#{@definition.key}-help-notes-title"}>
            Testing and production
          </h2>
          <p>{@help.testing_note}</p>
          <p>{@help.production_note}</p>
        </section>

        <section aria-labelledby={"oauth-provider-#{@definition.key}-help-links-title"}>
          <h2 id={"oauth-provider-#{@definition.key}-help-links-title"}>
            Official {@help.documentation_name} documentation
          </h2>
          <ul class="list-disc space-y-2 pl-6">
            <li :for={{label, href} <- @help.links}>
              <a
                href={href}
                target="_blank"
                rel="noopener noreferrer"
                aria-label={"#{label} (opens in a new tab)"}
              >
                {label}
              </a>
            </li>
          </ul>
        </section>
      </.dm_card>
    </section>
    """
  end
end

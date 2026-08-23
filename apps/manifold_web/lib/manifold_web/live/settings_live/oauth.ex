defmodule ManifoldWeb.SettingsLive.OAuth do
  use ManifoldWeb, :live_view

  alias Manifold.Connectors
  alias Manifold.Connectors.OAuthProviderCatalog
  alias Manifold.Connectors.ProviderSettings.Form

  @postgres_integer_max 2_147_483_647

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    definitions = OAuthProviderCatalog.list()

    case load_providers(definitions) do
      {:ok, providers} ->
        {:ok, assign(socket, page_title: "OAuth", providers: providers)}

      {:error, _error} ->
        {:ok,
         socket
         |> assign(page_title: "OAuth", providers: [])
         |> put_flash(:error, "OAuth configurations could not be loaded.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event(
        "save-provider",
        %{"provider" => provider, "oauth_provider_setting" => params},
        socket
      )
      when is_binary(provider) and is_map(params) do
    with {:ok, _definition} <- OAuthProviderCatalog.fetch(provider),
         {:ok, expected_lock_version} <-
           expected_save_lock_version(socket, provider, params) do
      result =
        Connectors.put_oauth_provider_setting(provider, params,
          expected_lock_version: expected_lock_version
        )

      case result do
        {:ok, _view} ->
          {:noreply,
           socket
           |> reload_provider(provider)
           |> put_flash(:info, "#{provider_title(socket, provider)} configuration saved.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign_provider_form(socket, provider, safe_changeset(changeset))}

        {:error, _error} ->
          reject_save(socket)
      end
    else
      {:error, _error} ->
        reject_save(socket)
    end
  end

  def handle_event("save-provider", _params, socket) do
    reject_save(socket)
  end

  def handle_event(
        "remove-provider",
        %{"provider" => provider, "lock_version" => lock_version},
        socket
      )
      when is_binary(provider) do
    with {:ok, _definition} <- OAuthProviderCatalog.fetch(provider) do
      case Connectors.remove_oauth_provider_setting(provider,
             expected_lock_version: parse_lock_version(lock_version)
           ) do
        {:ok, _view} ->
          {:noreply,
           socket
           |> reload_provider(provider)
           |> put_flash(:info, "#{provider_title(socket, provider)} configuration removed.")
           |> push_event("focus-oauth-provider", %{provider: provider})}

        {:error, _error} ->
          {:noreply,
           socket
           |> reload_provider(provider)
           |> put_flash(:error, "OAuth configuration could not be removed.")}
      end
    else
      {:error, _error} ->
        {:noreply, put_flash(socket, :error, "OAuth configuration could not be removed.")}
    end
  end

  def handle_event("remove-provider", _params, socket) do
    {:noreply, put_flash(socket, :error, "OAuth configuration could not be removed.")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>OAuth</h1>
          <p class="settings-intro">
            Configure the OAuth applications Manifold uses to receive and send mail.
          </p>
        </div>
      </div>

      <.dm_card
        :for={provider <- @providers}
        id={"oauth-provider-#{provider.definition.key}"}
        variant="bordered"
        shadow="sm"
        class="oauth-provider-card"
      >
        <:title>
          <span>{card_title(provider.definition)}</span>
          <.dm_badge
            variant={status_variant(provider.view.status)}
            size="sm"
            soft
            data-status={provider.view.status}
          >
            {status_label(provider.view.status)}
          </.dm_badge>
        </:title>

        <p class="settings-secondary">
          Application credentials used for {provider.definition.name} account connections.
        </p>

        <.dm_input
          id={"oauth-provider-#{provider.definition.key}-callback"}
          name={"oauth_provider_#{provider.definition.key}_callback"}
          label="Callback URI"
          value={provider.callback_uri}
          readonly
          helper="Copy this exact URI into the provider's OAuth application settings."
        />

        <.form
          for={provider.form}
          id={"oauth-provider-#{provider.definition.key}-form"}
          class="mailbox-setup-form"
          phx-submit="save-provider"
        >
          <input type="hidden" name="provider" value={provider.definition.key} />
          <input
            type="hidden"
            name={provider.form[:lock_version].name}
            value={provider.form[:lock_version].value}
          />

          <.dm_input
            id={"oauth-provider-#{provider.definition.key}-client-id"}
            field={provider.form[:client_id]}
            label="Client ID"
            autocomplete="off"
            required
          />

          <.dm_input
            id={"oauth-provider-#{provider.definition.key}-client-secret"}
            field={provider.form[:client_secret]}
            type="password"
            label="Client secret"
            value=""
            autocomplete="new-password"
            phx-patch-focused
            helper={secret_helper(provider.view)}
          />

          <button
            id={"save-oauth-provider-#{provider.definition.key}"}
            type="submit"
            class="settings-action settings-action-primary"
          >
            Save changes
          </button>
        </.form>

        <p :if={provider.view.client_secret_configured?} class="settings-hint">
          Changing the client ID or secret stops {provider.definition.name} receive and send until
          connected accounts are reconnected.
        </p>

        <div class="account-actions">
          <.link
            navigate={~p"/settings/oauth/#{provider.definition.key}/help"}
            class="settings-action"
          >
            Setup help
          </.link>
          <.link navigate={~p"/settings/accounts"} class="settings-action">
            Manage accounts
          </.link>
          <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#143 --%>
          <button
            :if={provider.view.client_secret_configured?}
            id={"remove-oauth-provider-#{provider.definition.key}"}
            type="button"
            class="settings-action settings-action-error"
            aria-label={"Remove #{card_title(provider.definition)} configuration"}
            phx-click="remove-provider"
            phx-value-provider={provider.definition.key}
            phx-value-lock_version={provider.view.lock_version}
            data-confirm={remove_confirmation(provider.definition)}
          >
            Remove configuration
          </button>
        </div>
      </.dm_card>
    </section>
    """
  end

  defp load_providers(definitions) do
    Enum.reduce_while(definitions, {:ok, []}, fn definition, {:ok, providers} ->
      case load_provider(definition) do
        {:ok, provider} -> {:cont, {:ok, [provider | providers]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, providers} -> {:ok, Enum.reverse(providers)}
      {:error, error} -> {:error, error}
    end
  end

  defp load_provider(definition) do
    with {:ok, view} <- Connectors.get_oauth_provider_setting(definition.key),
         %Ecto.Changeset{} = changeset <-
           Connectors.change_oauth_provider_setting(definition.key) do
      {:ok,
       %{
         definition: definition,
         view: view,
         form: to_form(changeset, as: :oauth_provider_setting),
         callback_uri: callback_uri(definition)
       }}
    else
      {:error, error} -> {:error, error}
    end
  end

  defp reload_provider(socket, provider) do
    case Enum.find(socket.assigns.providers, &(&1.definition.key == provider)) do
      nil ->
        socket

      %{definition: definition} ->
        case load_provider(definition) do
          {:ok, reloaded} ->
            update(socket, :providers, fn providers ->
              Enum.map(providers, fn existing ->
                if existing.definition.key == provider, do: reloaded, else: existing
              end)
            end)

          {:error, _error} ->
            socket
        end
    end
  end

  defp assign_provider_form(socket, provider, changeset) do
    update(socket, :providers, fn providers ->
      Enum.map(providers, fn existing ->
        if existing.definition.key == provider do
          %{existing | form: to_form(changeset, as: :oauth_provider_setting)}
        else
          existing
        end
      end)
    end)
  end

  defp safe_changeset(%Ecto.Changeset{} = changeset) do
    params =
      case changeset.params do
        params when is_map(params) -> Map.drop(params, ["client_secret", :client_secret])
        params -> params
      end

    data =
      case changeset.data do
        %Form{} = form -> %{form | client_secret: nil}
        data -> data
      end

    %{
      changeset
      | action: :validate,
        params: params,
        changes: Map.delete(changeset.changes, :client_secret),
        data: data
    }
  end

  defp callback_uri(definition) do
    ManifoldWeb.Endpoint.url()
    |> URI.merge(definition.callback_path)
    |> URI.to_string()
  end

  defp parse_lock_version(nil), do: nil
  defp parse_lock_version(""), do: nil

  defp parse_lock_version(version)
       when is_integer(version) and version > 0 and version <= @postgres_integer_max,
       do: version

  defp parse_lock_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {parsed, ""} when parsed > 0 and parsed <= @postgres_integer_max -> parsed
      _invalid -> :invalid
    end
  end

  defp parse_lock_version(_invalid), do: :invalid

  defp reject_save(socket) do
    {:noreply,
     socket
     |> put_flash(:error, "OAuth configuration could not be saved.")
     |> push_navigate(to: ~p"/settings/oauth", replace: true)}
  end

  defp expected_save_lock_version(socket, provider, params) do
    case Enum.find(socket.assigns.providers, &(&1.definition.key == provider)) do
      %{view: %{lock_version: nil}} ->
        optional_missing_lock_version(params)

      %{view: %{lock_version: lock_version}} when is_integer(lock_version) ->
        required_lock_version(params)

      _missing ->
        {:error, :invalid_lock_version}
    end
  end

  defp optional_missing_lock_version(params) do
    case Map.fetch(params, "lock_version") do
      :error -> {:ok, nil}
      {:ok, lock_version} when lock_version in [nil, ""] -> {:ok, nil}
      {:ok, _invalid} -> {:error, :invalid_lock_version}
    end
  end

  defp required_lock_version(params) do
    case Map.fetch(params, "lock_version") do
      {:ok, lock_version} ->
        case parse_lock_version(lock_version) do
          parsed when is_integer(parsed) -> {:ok, parsed}
          _invalid -> {:error, :invalid_lock_version}
        end

      :error ->
        {:error, :invalid_lock_version}
    end
  end

  defp provider_title(socket, provider) do
    socket.assigns.providers
    |> Enum.find(&(&1.definition.key == provider))
    |> case do
      %{definition: definition} -> card_title(definition)
      nil -> "OAuth"
    end
  end

  defp card_title(%{help: %{title: "Set up " <> title}}), do: title
  defp card_title(%{name: name}), do: name

  defp status_label(:configured), do: "Configured"
  defp status_label(:not_configured), do: "Not configured"
  defp status_label(:configuration_error), do: "Configuration error"

  defp status_variant(:configured), do: "success"
  defp status_variant(:not_configured), do: "neutral"
  defp status_variant(:configuration_error), do: "error"

  defp secret_helper(%{client_secret_configured?: true}),
    do: "Leave blank to keep the current secret."

  defp secret_helper(_view), do: "Required before this provider can connect accounts."

  defp remove_confirmation(definition) do
    "Remove #{card_title(definition)} configuration? #{definition.name} receive and send will stop, and connected accounts must reconnect."
  end
end

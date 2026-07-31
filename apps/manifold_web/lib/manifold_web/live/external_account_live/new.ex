defmodule ManifoldWeb.ExternalAccountLive.New do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.OAuth
  alias Manifold.Connectors.Provider.Token

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Add account",
       mailboxes: Accounts.list_active_mailboxes(),
       configured_providers: Connectors.configured_providers(),
       add_account_step: :account_type,
       selected_provider: nil,
       selected_mailbox_id: nil,
       device_authorization: nil,
       device_error: nil,
       device_polling?: false
     )}
  end

  @impl Phoenix.LiveView
  def handle_event(
        "choose-account-type",
        %{"type" => "external"},
        %{assigns: %{add_account_step: :account_type}} = socket
      ) do
    {:noreply, assign(socket, :add_account_step, :provider)}
  end

  def handle_event("choose-account-type", _params, socket), do: {:noreply, socket}

  def handle_event(
        "choose-provider",
        %{"provider" => provider},
        %{assigns: %{add_account_step: :provider}} = socket
      )
      when provider in ["gmail", "microsoft"] do
    if provider_configured?(socket.assigns.configured_providers, provider) do
      {:noreply,
       assign(socket,
         add_account_step: :mailbox,
         selected_provider: provider,
         selected_mailbox_id: nil,
         device_authorization: nil,
         device_error: nil,
         device_polling?: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("choose-provider", _params, socket), do: {:noreply, socket}

  def handle_event(
        "back-add-account",
        _params,
        %{assigns: %{add_account_step: :provider}} = socket
      ) do
    {:noreply,
     assign(socket,
       add_account_step: :account_type,
       selected_provider: nil,
       selected_mailbox_id: nil
     )}
  end

  def handle_event(
        "back-add-account",
        _params,
        %{assigns: %{add_account_step: :mailbox}} = socket
      ) do
    {:noreply, assign(socket, add_account_step: :provider, selected_mailbox_id: nil)}
  end

  def handle_event(
        "back-add-account",
        _params,
        %{assigns: %{add_account_step: :device}} = socket
      ) do
    {:noreply,
     assign(socket,
       add_account_step: :mailbox,
       device_authorization: nil,
       device_error: nil,
       device_polling?: false
     )}
  end

  def handle_event("back-add-account", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-add-account", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/settings/accounts")}
  end

  def handle_event(
        "select-add-account-mailbox",
        %{"mailbox_id" => mailbox_id},
        %{assigns: %{add_account_step: :mailbox}} = socket
      ) do
    selected_mailbox_id =
      if Enum.any?(socket.assigns.mailboxes, &(&1.id == mailbox_id)),
        do: mailbox_id,
        else: nil

    {:noreply, assign(socket, :selected_mailbox_id, selected_mailbox_id)}
  end

  def handle_event("select-add-account-mailbox", _params, socket) do
    {:noreply, assign(socket, :selected_mailbox_id, nil)}
  end

  def handle_event(
        "start-device-authorization",
        _params,
        %{
          assigns: %{
            add_account_step: :mailbox,
            selected_provider: "microsoft",
            selected_mailbox_id: mailbox_id
          }
        } = socket
      )
      when is_binary(mailbox_id) do
    case OAuth.start_device("microsoft", mailbox_id) do
      {:ok, authorization} ->
        socket =
          socket
          |> assign(
            add_account_step: :device,
            device_authorization: authorization,
            device_error: nil,
            device_polling?: true
          )
          |> schedule_device_poll(authorization.interval_seconds)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           device_error: "Microsoft device authorization could not be started.",
           device_polling?: false
         )}
    end
  end

  def handle_event("start-device-authorization", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_info(
        :poll_device_authorization,
        %{
          assigns: %{
            add_account_step: :device,
            device_polling?: true,
            device_authorization: %{state: state},
            selected_provider: provider
          }
        } = socket
      ) do
    case OAuth.poll_device(provider, state) do
      {:ok, :authorization_pending} ->
        {:noreply, schedule_device_poll(socket, socket.assigns.device_authorization.interval_seconds)}

      {:ok, {:slow_down, interval}} ->
        authorization = %{socket.assigns.device_authorization | interval_seconds: interval}

        {:noreply,
         socket
         |> assign(:device_authorization, authorization)
         |> schedule_device_poll(interval)}

      {:ok, %Token{} = token, consumed} ->
        case Connectors.complete_device_authorization(provider, token, consumed) do
          {:ok, _account} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{provider_name(provider)} account connected.")
             |> push_navigate(to: ~p"/settings/accounts")}

          {:error, _reason} ->
            {:noreply,
             assign(socket,
               device_polling?: false,
               device_error: "The #{provider_name(provider)} account could not be connected."
             )}
        end

      {:error, %{reason: reason}} ->
        {:noreply,
         assign(socket,
           device_polling?: false,
           device_error: device_error_message(reason, provider)
         )}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           device_polling?: false,
           device_error: "The #{provider_name(provider)} authorization failed."
         )}
    end
  end

  def handle_info(:poll_device_authorization, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>Add an email account</h1>
          <p class="settings-intro">
            Sign in with the provider like a desktop mail client (public OAuth,
            no password stored here). Manifold then imports mail read-only through
            the provider API—not IMAP.
          </p>
        </div>
        <div class="settings-heading-actions">
          <nav class="settings-nav" aria-label="Settings">
            <.link navigate={~p"/settings/accounts"}>Accounts</.link>
            <.link navigate={~p"/mailboxes"}>Mailboxes</.link>
            <.link navigate={~p"/domains"}>Domains</.link>
          </nav>
        </div>
      </div>

      <section
        id="add-account-panel"
        class="add-account-panel"
        aria-labelledby="add-account-title"
      >
        <header class="add-account-panel-header">
          <div>
            <span class="add-account-step">{add_account_step_label(@add_account_step)}</span>
            <h2 id="add-account-title">Add an email account</h2>
          </div>
        </header>

        <div :if={@add_account_step == :account_type}>
          <h3 id="add-account-type-heading" tabindex="-1" phx-mounted={JS.focus()}>
            What kind of account are you adding?
          </h3>
          <button
            id="external-account-type"
            type="button"
            class="add-account-choice"
            phx-click="choose-account-type"
            phx-value-type="external"
          >
            <.dm_mdi name="cloud-outline" />
            <span>
              <strong>External account</strong>
              <small>
                Sign in with Google or Microsoft, then import into a local mailbox.
              </small>
            </span>
          </button>
        </div>

        <div :if={@add_account_step == :provider}>
          <h3 id="add-account-provider-heading" tabindex="-1" phx-mounted={JS.focus()}>
            Choose a provider
          </h3>
          <div class="add-account-choices">
            <button
              :for={provider <- ["gmail", "microsoft"]}
              id={"provider-#{provider}"}
              type="button"
              class="add-account-choice"
              disabled={!provider_configured?(@configured_providers, provider)}
              phx-click="choose-provider"
              phx-value-provider={provider}
            >
              <.dm_mdi name={provider_icon(provider)} />
              <span>
                <strong>{provider_name(provider)}</strong>
                <small>{provider_subtitle(provider, @configured_providers)}</small>
              </span>
            </button>
          </div>
        </div>

        <div :if={@add_account_step == :mailbox}>
          <h3 id="add-account-mailbox-heading" tabindex="-1" phx-mounted={JS.focus()}>
            Choose a local mailbox
          </h3>
          <p class="settings-secondary">
            Imported {provider_name(@selected_provider)} mail will land here.
            {provider_auth_hint(@selected_provider)}
          </p>

          <form
            :if={@mailboxes != []}
            id="add-account-mailbox-form"
            phx-change="select-add-account-mailbox"
          >
            <label for="add-account-mailbox-id">Local mailbox</label>
            <select id="add-account-mailbox-id" name="mailbox_id">
              <option value="">Select a mailbox</option>
              <option
                :for={mailbox <- @mailboxes}
                value={mailbox.id}
                selected={mailbox.id == @selected_mailbox_id}
              >
                {mailbox_address(mailbox)}
              </option>
            </select>
          </form>

          <div :if={@mailboxes == []} id="add-account-no-mailboxes" class="settings-empty">
            <p>Create an active local mailbox before connecting an external account.</p>
            <.link id="manage-mailboxes-link" navigate={~p"/mailboxes"}>
              Manage mailboxes
            </.link>
          </div>

          <p :if={@device_error} id="device-start-error" class="settings-error" role="alert">
            {@device_error}
          </p>

          <a
            :if={@selected_mailbox_id && @selected_provider == "gmail"}
            id="continue-add-account"
            class="settings-action settings-action-primary"
            href={~p"/connectors/gmail/start?#{[mailbox_id: @selected_mailbox_id]}"}
          >
            Sign in with Google
          </a>

          <button
            :if={@selected_mailbox_id && @selected_provider == "microsoft"}
            id="continue-add-account"
            type="button"
            class="settings-action settings-action-primary"
            phx-click="start-device-authorization"
          >
            Sign in with Microsoft
          </button>
        </div>

        <div :if={@add_account_step == :device && @device_authorization} id="device-authorization">
          <h3 id="add-account-device-heading" tabindex="-1" phx-mounted={JS.focus()}>
            Approve Microsoft 365 access
          </h3>
          <p class="settings-secondary">
            Open the link below (or visit the verification URI on any device), enter
            this code, and approve read-only mail access—same public-client consent
            model as a desktop mail app, without registering a redirect URI.
          </p>

          <p class="device-user-code" aria-label="Device user code">
            <code id="device-user-code">{@device_authorization.user_code}</code>
          </p>

          <p class="settings-secondary">
            <a
              id="device-verification-link"
              href={
                @device_authorization.verification_uri_complete ||
                  @device_authorization.verification_uri
              }
              target="_blank"
              rel="noopener noreferrer"
            >
              {@device_authorization.verification_uri}
            </a>
          </p>

          <p
            :if={@device_polling?}
            id="device-waiting"
            class="settings-secondary"
            aria-live="polite"
          >
            Waiting for authorization…
          </p>

          <p :if={@device_error} id="device-error" class="settings-error" role="alert">
            {@device_error}
          </p>
        </div>

        <footer class="add-account-panel-footer">
          <button
            :if={@add_account_step != :account_type}
            id="back-add-account"
            type="button"
            class="settings-action"
            phx-click="back-add-account"
          >
            Back
          </button>
          <button
            id="cancel-add-account"
            type="button"
            class="settings-action"
            phx-click="cancel-add-account"
          >
            Cancel
          </button>
        </footer>
      </section>
    </section>
    """
  end

  defp schedule_device_poll(socket, interval_seconds)
       when is_integer(interval_seconds) and interval_seconds > 0 do
    Process.send_after(self(), :poll_device_authorization, interval_seconds * 1_000)
    socket
  end

  defp mailbox_address(mailbox),
    do: mailbox.local_part <> "@" <> mailbox.domain.normalized_domain

  defp provider_name("gmail"), do: "Gmail"
  defp provider_name("microsoft"), do: "Microsoft 365"
  defp provider_name(provider), do: provider

  defp add_account_step_label(:account_type), do: "Step 1 of 3"
  defp add_account_step_label(:provider), do: "Step 2 of 3"
  defp add_account_step_label(:mailbox), do: "Step 3 of 3"
  defp add_account_step_label(:device), do: "Authorize"

  defp provider_configured?(configured_providers, provider),
    do: provider in configured_providers

  defp provider_subtitle(provider, configured_providers) do
    if provider_configured?(configured_providers, provider) do
      provider_ready_subtitle(provider)
    else
      provider_missing_subtitle(provider)
    end
  end

  defp provider_ready_subtitle("gmail"),
    do: "Browser sign-in (public/Desktop client). Read-only Gmail API sync."

  defp provider_ready_subtitle("microsoft"),
    do: "Device-code sign-in (client ID only). Read-only Graph sync."

  defp provider_ready_subtitle(_provider), do: "Import mail using read-only access."

  defp provider_missing_subtitle("gmail"),
    do: "Provider not configured — set MANIFOLD_GMAIL_CLIENT_ID"

  defp provider_missing_subtitle("microsoft"),
    do: "Provider not configured — set MANIFOLD_MICROSOFT_CLIENT_ID"

  defp provider_missing_subtitle(_provider), do: "Provider not configured"

  defp provider_auth_hint("gmail"),
    do: "Next: Google browser consent with PKCE (client secret optional)."

  defp provider_auth_hint("microsoft"),
    do: "Next: Microsoft device code on any signed-in device (no redirect URI)."

  defp provider_auth_hint(_provider), do: ""

  defp provider_icon("gmail"), do: "gmail"
  defp provider_icon("microsoft"), do: "microsoft"

  defp device_error_message(:authorization_declined, provider),
    do: "The #{provider_name(provider)} authorization was declined."

  defp device_error_message(:device_code_expired, provider),
    do: "The #{provider_name(provider)} device code expired. Go back and try again."

  defp device_error_message(:oauth_state_expired, provider),
    do: "The #{provider_name(provider)} device code expired. Go back and try again."

  defp device_error_message(_reason, provider),
    do: "The #{provider_name(provider)} authorization failed."
end

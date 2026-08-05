defmodule ManifoldWeb.ExternalAccountLive.New do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Core.Error
  alias Manifold.Mail

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
       imap_form: empty_imap_form(),
       imap_error: nil,
       imap_saving: false
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, restore_mailbox_handoff(socket, params)}
  end

  @impl Phoenix.LiveView
  def handle_event(
        "choose-account-type",
        %{"type" => "external"},
        %{assigns: %{add_account_step: :account_type}} = socket
      ) do
    {:noreply, assign(socket, :add_account_step, :provider)}
  end

  def handle_event(
        "choose-account-type",
        %{"type" => "imap"},
        %{assigns: %{add_account_step: :account_type}} = socket
      ) do
    {:noreply,
     assign(socket,
       add_account_step: :imap_form,
       imap_form: empty_imap_form(),
       imap_error: nil
     )}
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
         selected_mailbox_id: nil
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
        %{assigns: %{add_account_step: :imap_form}} = socket
      ) do
    {:noreply,
     assign(socket,
       add_account_step: :account_type,
       imap_form: empty_imap_form(),
       imap_error: nil
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
        "imap-form-change",
        %{"imap" => params},
        %{assigns: %{add_account_step: :imap_form}} = socket
      ) do
    form = merge_imap_form(socket.assigns.imap_form, params)
    {:noreply, assign(socket, imap_form: form, imap_error: nil)}
  end

  def handle_event("imap-form-change", _params, socket), do: {:noreply, socket}

  def handle_event(
        "save-imap-account",
        %{"imap" => params},
        %{assigns: %{add_account_step: :imap_form, imap_saving: false}} = socket
      ) do
    form = merge_imap_form(socket.assigns.imap_form, params)
    socket = assign(socket, imap_form: form, imap_saving: true, imap_error: nil)

    attrs = %{
      email_address: form.email_address,
      username: form.username,
      password: form.password,
      host: form.host,
      port: form.port,
      tls_mode: form.tls_mode
    }

    case Connectors.create_imap_account(attrs) do
      {:ok, account} ->
        {:ok, folders} = Mail.list_folders(account.mailbox_id)
        inbox = Enum.find(folders, &(&1.kind == "inbox"))

        {:noreply,
         socket
         |> assign(imap_saving: false)
         |> push_navigate(to: ~p"/mail/#{account.mailbox_id}/folders/#{inbox.id}")}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           imap_saving: false,
           imap_error: imap_error_message(reason)
         )}
    end
  end

  def handle_event("save-imap-account", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>Add an email account</h1>
          <p class="settings-intro">
            Connect a provider account and choose where imported mail should land.
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
          <div class="add-account-choices">
            <button
              id="external-account-type"
              type="button"
              class="add-account-choice"
              phx-click="choose-account-type"
              phx-value-type="external"
            >
              <.dm_mdi name="cloud-outline" />
              <span>
                <strong>Cloud account</strong>
                <small>Connect Gmail or Microsoft 365 with OAuth.</small>
              </span>
            </button>
            <button
              id="imap-account-type"
              type="button"
              class="add-account-choice"
              phx-click="choose-account-type"
              phx-value-type="imap"
            >
              <.dm_mdi name="email-outline" />
              <span>
                <strong>IMAP account</strong>
                <small>Connect any IMAP inbox with a password.</small>
              </span>
            </button>
          </div>
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
                <small :if={provider_configured?(@configured_providers, provider)}>
                  Import mail using read-only access.
                </small>
                <small :if={!provider_configured?(@configured_providers, provider)}>
                  Provider not configured
                </small>
              </span>
            </button>
          </div>
        </div>

        <div :if={@add_account_step == :mailbox}>
          <h3 id="add-account-mailbox-heading" tabindex="-1" phx-mounted={JS.focus()}>
            Choose a local mailbox
          </h3>
          <p class="settings-secondary">
            Imported {provider_name(@selected_provider)} mail will be delivered here.
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
            <.link
              id="create-local-mailbox-link"
              navigate={~p"/mailboxes?#{[source: "external_account", provider: @selected_provider]}"}
            >
              Create local mailbox
            </.link>
          </div>

          <a
            :if={@selected_mailbox_id}
            id="continue-add-account"
            class="settings-action settings-action-primary"
            href={~p"/connectors/#{@selected_provider}/start?#{[mailbox_id: @selected_mailbox_id]}"}
          >
            Continue to {provider_name(@selected_provider)}
          </a>
        </div>

        <div :if={@add_account_step == :imap_form}>
          <h3 id="add-account-imap-heading" tabindex="-1" phx-mounted={JS.focus()}>
            IMAP connection
          </h3>
          <p class="settings-secondary">
            Manifold will create a local mailbox from the email address and sync INBOX read-only.
          </p>

          <form
            id="imap-account-form"
            phx-change="imap-form-change"
            phx-submit="save-imap-account"
          >
            <label for="imap-email-address">Email address</label>
            <input
              id="imap-email-address"
              type="email"
              name="imap[email_address]"
              value={@imap_form.email_address}
              required
              autocomplete="username"
            />

            <label for="imap-username">Username</label>
            <input
              id="imap-username"
              type="text"
              name="imap[username]"
              value={@imap_form.username}
              required
              autocomplete="username"
            />

            <label for="imap-password">Password</label>
            <input
              id="imap-password"
              type="password"
              name="imap[password]"
              value={@imap_form.password}
              required
              autocomplete="current-password"
            />

            <label for="imap-host">Host</label>
            <input
              id="imap-host"
              type="text"
              name="imap[host]"
              value={@imap_form.host}
              required
              autocomplete="off"
            />

            <label for="imap-port">Port</label>
            <input
              id="imap-port"
              type="number"
              name="imap[port]"
              value={@imap_form.port}
              required
              min="1"
              max="65535"
            />

            <label for="imap-tls-mode">TLS mode</label>
            <select id="imap-tls-mode" name="imap[tls_mode]">
              <option value="ssl" selected={@imap_form.tls_mode == "ssl"}>SSL</option>
              <option value="starttls" selected={@imap_form.tls_mode == "starttls"}>STARTTLS</option>
            </select>

            <p :if={@imap_error} id="imap-account-error" class="settings-error" role="alert">
              {@imap_error}
            </p>

            <button
              id="save-imap-account"
              type="submit"
              class="settings-action settings-action-primary"
              disabled={@imap_saving}
            >
              {if @imap_saving, do: "Connecting…", else: "Connect IMAP account"}
            </button>
          </form>
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

  defp empty_imap_form do
    %{
      email_address: "",
      username: "",
      password: "",
      host: "",
      port: "993",
      tls_mode: "ssl"
    }
  end

  defp merge_imap_form(form, params) when is_map(params) do
    email = Map.get(params, "email_address", form.email_address)
    username = Map.get(params, "username", form.username)

    username =
      cond do
        username in [nil, ""] and is_binary(email) and email != "" -> email
        true -> username || ""
      end

    %{
      email_address: email || "",
      username: username,
      password: Map.get(params, "password", form.password) || "",
      host: Map.get(params, "host", form.host) || "",
      port: Map.get(params, "port", form.port) || "993",
      tls_mode: Map.get(params, "tls_mode", form.tls_mode) || "ssl"
    }
  end

  defp imap_error_message(%ProviderError{message: message}) when is_binary(message), do: message
  defp imap_error_message(%Error{message: message}) when is_binary(message), do: message
  defp imap_error_message(%Ecto.Changeset{}), do: "Could not save IMAP account settings."
  defp imap_error_message(_), do: "Could not connect to the IMAP server."

  defp mailbox_address(mailbox),
    do: mailbox.local_part <> "@" <> mailbox.domain.normalized_domain

  defp provider_name("gmail"), do: "Gmail"
  defp provider_name("microsoft"), do: "Microsoft 365"
  defp provider_name(provider), do: provider

  defp add_account_step_label(:account_type), do: "Step 1"
  defp add_account_step_label(:provider), do: "Step 2 of 3"
  defp add_account_step_label(:mailbox), do: "Step 3 of 3"
  defp add_account_step_label(:imap_form), do: "Step 2 of 2"

  defp provider_configured?(configured_providers, provider),
    do: provider in configured_providers

  defp provider_icon("gmail"), do: "gmail"
  defp provider_icon("microsoft"), do: "microsoft"

  defp restore_mailbox_handoff(
         socket,
         %{"provider" => provider, "mailbox_id" => mailbox_id}
       )
       when provider in ["gmail", "microsoft"] do
    valid_provider =
      provider_configured?(socket.assigns.configured_providers, provider)

    valid_mailbox =
      Enum.any?(socket.assigns.mailboxes, &(&1.id == mailbox_id))

    if valid_provider and valid_mailbox do
      assign(socket,
        add_account_step: :mailbox,
        selected_provider: provider,
        selected_mailbox_id: mailbox_id
      )
    else
      reset_add_account(socket)
    end
  end

  defp restore_mailbox_handoff(socket, _params), do: reset_add_account(socket)

  defp reset_add_account(socket) do
    assign(socket,
      add_account_step: :account_type,
      selected_provider: nil,
      selected_mailbox_id: nil,
      imap_form: empty_imap_form(),
      imap_error: nil,
      imap_saving: false
    )
  end
end

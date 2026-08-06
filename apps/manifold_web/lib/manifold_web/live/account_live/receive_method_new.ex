defmodule ManifoldWeb.AccountLive.ReceiveMethodNew do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Core.Error

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    case Accounts.get_account(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Account not found.")
         |> push_navigate(to: ~p"/settings/accounts")}

      account ->
        {:ok,
         assign(socket,
           page_title: "Add receive method",
           account: account,
           address: Accounts.account_address(account),
           configured_providers: Connectors.configured_providers(),
           step: :choose_kind,
           selected_kind: nil,
           imap_form: empty_imap_form(account),
           imap_error: nil,
           imap_notice: nil,
           imap_busy: false,
           eas_form: empty_eas_form(account),
           eas_error: nil,
           eas_notice: nil,
           eas_busy: false
         )}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("choose-kind", %{"kind" => kind}, socket)
      when kind in ["gmail", "microsoft", "imap", "pop3", "eas", "ews"] do
    cond do
      kind in ["gmail", "microsoft"] ->
        if kind in socket.assigns.configured_providers do
          {:noreply, assign(socket, step: :oauth_confirm, selected_kind: kind)}
        else
          {:noreply, put_flash(socket, :error, "#{kind_label(kind)} is not configured.")}
        end

      kind == "imap" ->
        {:noreply,
         assign(socket,
           step: :imap_form,
           selected_kind: kind,
           imap_form: empty_imap_form(socket.assigns.account),
           imap_error: nil,
           imap_notice: nil
         )}

      kind == "eas" ->
        {:noreply,
         assign(socket,
           step: :eas_form,
           selected_kind: kind,
           eas_form: empty_eas_form(socket.assigns.account),
           eas_error: nil,
           eas_notice: nil
         )}

      true ->
        case Connectors.create_placeholder_receive_method(socket.assigns.account.id, kind) do
          {:ok, _method} ->
            {:noreply,
             socket
             |> put_flash(:info, "#{kind_label(kind)} placeholder added (not implemented yet).")
             |> push_navigate(to: ~p"/settings/accounts/#{socket.assigns.account.id}")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Could not add #{kind_label(kind)}.")}
        end
    end
  end

  def handle_event("back", _params, socket) do
    if socket.assigns.imap_busy or socket.assigns.eas_busy do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         step: :choose_kind,
         selected_kind: nil,
         imap_form: empty_imap_form(socket.assigns.account),
         imap_error: nil,
         imap_notice: nil,
         eas_form: empty_eas_form(socket.assigns.account),
         eas_error: nil,
         eas_notice: nil
       )}
    end
  end

  def handle_event("validate-imap", %{"imap" => params}, socket) do
    if socket.assigns.imap_busy do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket, imap_form: to_form(params, as: :imap), imap_error: nil, imap_notice: nil)}
    end
  end

  def handle_event("test-imap", _params, %{assigns: %{imap_busy: false}} = socket) do
    params = imap_form_params(socket.assigns.imap_form)
    attrs = imap_attrs(params, socket)

    socket =
      socket
      |> assign(imap_busy: true, imap_error: nil, imap_notice: nil)
      |> start_async(:test_imap, fn -> Connectors.test_imap_connection(attrs) end)

    {:noreply, socket}
  end

  def handle_event("test-imap", _params, socket), do: {:noreply, socket}

  def handle_event(
        "save-imap",
        %{"imap" => params},
        %{assigns: %{imap_busy: false}} = socket
      ) do
    attrs = imap_attrs(params, socket)

    socket =
      socket
      |> assign(
        imap_busy: true,
        imap_form: to_form(params, as: :imap),
        imap_error: nil,
        imap_notice: nil
      )
      |> start_async(:save_imap, fn -> Connectors.create_imap_account(attrs) end)

    {:noreply, socket}
  end

  def handle_event("save-imap", _params, socket), do: {:noreply, socket}

  def handle_event("validate-eas", %{"eas" => params}, socket) do
    if socket.assigns.eas_busy do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket, eas_form: to_form(params, as: :eas), eas_error: nil, eas_notice: nil)}
    end
  end

  def handle_event("test-eas", _params, %{assigns: %{eas_busy: false}} = socket) do
    params = eas_form_params(socket.assigns.eas_form)
    attrs = eas_attrs(params, socket)

    socket =
      socket
      |> assign(eas_busy: true, eas_error: nil, eas_notice: nil)
      |> start_async(:test_eas, fn -> Connectors.test_eas_connection(attrs) end)

    {:noreply, socket}
  end

  def handle_event("test-eas", _params, socket), do: {:noreply, socket}

  def handle_event(
        "save-eas",
        %{"eas" => params},
        %{assigns: %{eas_busy: false}} = socket
      ) do
    attrs = eas_attrs(params, socket)

    socket =
      socket
      |> assign(
        eas_busy: true,
        eas_form: to_form(params, as: :eas),
        eas_error: nil,
        eas_notice: nil
      )
      |> start_async(:save_eas, fn -> Connectors.create_eas_account(attrs) end)

    {:noreply, socket}
  end

  def handle_event("save-eas", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_async(:test_imap, {:ok, :ok}, socket) do
    Process.send_after(self(), :unlock_imap_busy, 1_000)

    {:noreply,
     assign(socket,
       imap_notice: "Connection succeeded.",
       imap_error: nil
     )}
  end

  def handle_async(:test_imap, {:ok, {:error, reason}}, socket) do
    Process.send_after(self(), :unlock_imap_busy, 1_000)
    {:noreply, assign(socket, imap_error: format_error(reason), imap_notice: nil)}
  end

  def handle_async(:test_imap, {:exit, _reason}, socket) do
    Process.send_after(self(), :unlock_imap_busy, 1_000)
    {:noreply, assign(socket, imap_error: "Something went wrong.", imap_notice: nil)}
  end

  def handle_async(:save_imap, {:ok, {:ok, _method}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "IMAP receive method added and enabled.")
     |> push_navigate(to: ~p"/settings/accounts/#{socket.assigns.account.id}")}
  end

  def handle_async(:save_imap, {:ok, {:error, reason}}, socket) do
    Process.send_after(self(), :unlock_imap_busy, 1_000)
    {:noreply, assign(socket, imap_error: format_error(reason), imap_notice: nil)}
  end

  def handle_async(:save_imap, {:exit, _reason}, socket) do
    Process.send_after(self(), :unlock_imap_busy, 1_000)
    {:noreply, assign(socket, imap_error: "Something went wrong.", imap_notice: nil)}
  end

  def handle_async(:test_eas, {:ok, :ok}, socket) do
    Process.send_after(self(), :unlock_eas_busy, 1_000)

    {:noreply,
     assign(socket,
       eas_notice: "Connection succeeded.",
       eas_error: nil
     )}
  end

  def handle_async(:test_eas, {:ok, {:error, reason}}, socket) do
    Process.send_after(self(), :unlock_eas_busy, 1_000)
    {:noreply, assign(socket, eas_error: format_error(reason), eas_notice: nil)}
  end

  def handle_async(:test_eas, {:exit, _reason}, socket) do
    Process.send_after(self(), :unlock_eas_busy, 1_000)
    {:noreply, assign(socket, eas_error: "Something went wrong.", eas_notice: nil)}
  end

  def handle_async(:save_eas, {:ok, {:ok, _method}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "EAS receive method added and enabled.")
     |> push_navigate(to: ~p"/settings/accounts/#{socket.assigns.account.id}")}
  end

  def handle_async(:save_eas, {:ok, {:error, reason}}, socket) do
    Process.send_after(self(), :unlock_eas_busy, 1_000)
    {:noreply, assign(socket, eas_error: format_error(reason), eas_notice: nil)}
  end

  def handle_async(:save_eas, {:exit, _reason}, socket) do
    Process.send_after(self(), :unlock_eas_busy, 1_000)
    {:noreply, assign(socket, eas_error: "Something went wrong.", eas_notice: nil)}
  end

  @impl Phoenix.LiveView
  def handle_info(:unlock_imap_busy, socket) do
    {:noreply, assign(socket, imap_busy: false)}
  end

  def handle_info(:unlock_eas_busy, socket) do
    {:noreply, assign(socket, eas_busy: false)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>Add receive method</h1>
          <p class="settings-intro">
            Connect a source that imports mail into {@account.name || @account.local_part}
            ({@address}).
          </p>
        </div>
        <div class="settings-heading-actions">
          <.link navigate={~p"/settings/accounts/#{@account.id}"} class="settings-action">
            Cancel
          </.link>
        </div>
      </div>

      <div class="add-account-panel" id="add-receive-method-panel">
        <div :if={@step == :choose_kind}>
          <div class="add-account-panel-header">
            <div>
              <p class="add-account-step">Step 1</p>
              <h2>Choose receive method</h2>
            </div>
          </div>

          <div class="add-account-choices">
            <button
              :for={kind <- ~w(gmail microsoft imap pop3 eas ews)}
              type="button"
              class="add-account-choice"
              phx-click="choose-kind"
              phx-value-kind={kind}
              disabled={kind in ~w(gmail microsoft) and kind not in @configured_providers}
            >
              <.dm_mdi name={kind_icon(kind)} />
              <span>
                <strong>{kind_label(kind)}</strong>
                <small>{kind_description(kind, @configured_providers)}</small>
              </span>
            </button>
          </div>
        </div>

        <div :if={@step == :oauth_confirm}>
          <div class="add-account-panel-header">
            <div>
              <p class="add-account-step">Step 2</p>
              <h2>Connect {kind_label(@selected_kind)}</h2>
            </div>
          </div>
          <p class="settings-intro">
            Authorize {kind_label(@selected_kind)} to import mail into this account.
          </p>
          <div class="add-account-panel-footer">
            <button type="button" class="settings-action" phx-click="back">Back</button>
            <.link
              href={~p"/connectors/#{@selected_kind}/start?account_id=#{@account.id}"}
              class="settings-action settings-action-primary"
            >
              Continue with {kind_label(@selected_kind)}
            </.link>
          </div>
        </div>

        <div :if={@step == :imap_form}>
          <div class="add-account-panel-header">
            <div>
              <p class="add-account-step">Step 2</p>
              <h2>IMAP settings</h2>
            </div>
          </div>
          <p :if={@imap_error} class="settings-error">{@imap_error}</p>
          <p :if={@imap_notice} class="settings-success">{@imap_notice}</p>
          <.form
            for={@imap_form}
            id="imap-account-form"
            phx-change="validate-imap"
            phx-submit="save-imap"
          >
            <label>
              Email
              <input
                type="email"
                name={@imap_form[:email_address].name}
                value={@imap_form[:email_address].value}
                required
              />
            </label>
            <label>
              Host
              <input type="text" name={@imap_form[:host].name} value={@imap_form[:host].value} required />
            </label>
            <label>
              Port
              <input type="number" name={@imap_form[:port].name} value={@imap_form[:port].value} required />
            </label>
            <label>
              TLS mode
              <select name={@imap_form[:tls_mode].name}>
                <option value="tls" selected={@imap_form[:tls_mode].value in ["tls", "ssl"]}>
                  SSL/TLS (Implicit TLS)
                </option>
                <option value="starttls" selected={@imap_form[:tls_mode].value == "starttls"}>
                  STARTTLS
                </option>
              </select>
            </label>
            <label>
              Username
              <input
                type="text"
                name={@imap_form[:username].name}
                value={@imap_form[:username].value}
                required
              />
            </label>
            <label>
              Password
              <span class="settings-hint">
                Use an app / authorization password when required (no spaces).
              </span>
              <input
                type="password"
                name={@imap_form[:password].name}
                value={@imap_form[:password].value}
                required
                autocomplete="current-password"
              />
            </label>
            <div class="add-account-panel-footer">
              <button type="button" class="settings-action" phx-click="back" disabled={@imap_busy}>
                Back
              </button>
              <button
                type="button"
                id="test-imap-connection"
                class="settings-action"
                phx-click="test-imap"
                phx-disable-with="Testing…"
                disabled={@imap_busy}
              >
                Test connection
              </button>
              <button
                type="submit"
                class="settings-action settings-action-primary"
                phx-disable-with="Saving…"
                disabled={@imap_busy}
              >
                Save IMAP
              </button>
            </div>
          </.form>
        </div>

        <div :if={@step == :eas_form}>
          <div class="add-account-panel-header">
            <div>
              <p class="add-account-step">Step 2</p>
              <h2>EAS settings</h2>
            </div>
          </div>
          <p :if={@eas_error} class="settings-error">{@eas_error}</p>
          <p :if={@eas_notice} class="settings-success">{@eas_notice}</p>
          <.form
            for={@eas_form}
            id="eas-account-form"
            phx-change="validate-eas"
            phx-submit="save-eas"
          >
            <label>
              Email
              <input
                type="email"
                name={@eas_form[:email_address].name}
                value={@eas_form[:email_address].value}
                required
              />
            </label>
            <label>
              Host
              <input type="text" name={@eas_form[:host].name} value={@eas_form[:host].value} required />
            </label>
            <label>
              Port
              <input type="number" name={@eas_form[:port].name} value={@eas_form[:port].value} required />
            </label>
            <label>
              Path
              <span class="settings-hint">Usually /Microsoft-Server-ActiveSync</span>
              <input type="text" name={@eas_form[:path].name} value={@eas_form[:path].value} required />
            </label>
            <label>
              Username
              <span class="settings-hint">May be DOMAIN\\user or user@domain</span>
              <input
                type="text"
                name={@eas_form[:username].name}
                value={@eas_form[:username].value}
                required
              />
            </label>
            <label>
              Password
              <input
                type="password"
                name={@eas_form[:password].name}
                value={@eas_form[:password].value}
                required
                autocomplete="current-password"
              />
            </label>
            <div class="add-account-panel-footer">
              <button type="button" class="settings-action" phx-click="back" disabled={@eas_busy}>
                Back
              </button>
              <button
                type="button"
                id="test-eas-connection"
                class="settings-action"
                phx-click="test-eas"
                phx-disable-with="Testing…"
                disabled={@eas_busy}
              >
                Test connection
              </button>
              <button
                type="submit"
                class="settings-action settings-action-primary"
                phx-disable-with="Saving…"
                disabled={@eas_busy}
              >
                Save EAS
              </button>
            </div>
          </.form>
        </div>
      </div>
    </section>
    """
  end

  defp imap_attrs(params, socket) do
    params
    |> Map.put("account_id", socket.assigns.account.id)
    |> Map.put_new("email_address", socket.assigns.address)
  end

  defp eas_attrs(params, socket) do
    params
    |> Map.put("account_id", socket.assigns.account.id)
    |> Map.put_new("email_address", socket.assigns.address)
  end

  defp imap_form_params(form) do
    %{
      "email_address" => form[:email_address].value,
      "host" => form[:host].value,
      "port" => form[:port].value,
      "tls_mode" => form[:tls_mode].value,
      "username" => form[:username].value,
      "password" => form[:password].value
    }
  end

  defp eas_form_params(form) do
    %{
      "email_address" => form[:email_address].value,
      "host" => form[:host].value,
      "port" => form[:port].value,
      "path" => form[:path].value,
      "username" => form[:username].value,
      "password" => form[:password].value
    }
  end

  defp empty_imap_form(account) do
    address = Accounts.account_address(account)

    to_form(
      %{
        "email_address" => address,
        "host" => "",
        "port" => "993",
        "tls_mode" => "tls",
        "username" => address,
        "password" => ""
      },
      as: :imap
    )
  end

  defp empty_eas_form(account) do
    address = Accounts.account_address(account)

    to_form(
      %{
        "email_address" => address,
        "host" => "",
        "port" => "443",
        "path" => "/Microsoft-Server-ActiveSync",
        "username" => address,
        "password" => ""
      },
      as: :eas
    )
  end

  defp kind_label("gmail"), do: "Gmail"
  defp kind_label("microsoft"), do: "Microsoft Graph"
  defp kind_label("imap"), do: "IMAP"
  defp kind_label("pop3"), do: "POP3"
  defp kind_label("eas"), do: "EAS"
  defp kind_label("ews"), do: "EWS"
  defp kind_label(kind), do: kind

  defp kind_icon("gmail"), do: "gmail"
  defp kind_icon("microsoft"), do: "microsoft"
  defp kind_icon("imap"), do: "email-outline"
  defp kind_icon("pop3"), do: "inbox-arrow-down-outline"
  defp kind_icon("eas"), do: "cellphone-link"
  defp kind_icon("ews"), do: "microsoft-outlook"
  defp kind_icon(_), do: "email-outline"

  defp kind_description("gmail", configured) do
    if "gmail" in configured, do: "Connect with Google OAuth", else: "Provider not configured"
  end

  defp kind_description("microsoft", configured) do
    if "microsoft" in configured,
      do: "Connect with Microsoft OAuth",
      else: "Provider not configured"
  end

  defp kind_description("imap", _configured), do: "Host, port, username, and password"

  defp kind_description("eas", _configured),
    do: "Exchange ActiveSync — host, username, and password"

  defp kind_description("pop3", _configured), do: "Placeholder — not implemented yet"
  defp kind_description("ews", _configured), do: "Placeholder — not implemented yet"
  defp kind_description(_, _), do: ""

  defp format_error(%Error{message: message}), do: message
  defp format_error(%ProviderError{message: message}), do: message
  defp format_error(%Ecto.Changeset{}), do: "Invalid settings."
  defp format_error(_), do: "Something went wrong."
end

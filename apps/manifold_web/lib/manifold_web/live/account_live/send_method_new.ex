defmodule ManifoldWeb.AccountLive.SendMethodNew do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Core.Error

  @oauth_providers ~w(gmail microsoft)

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
           page_title: "Add send method",
           account: account,
           address: Accounts.account_address(account),
           configured_providers: Connectors.configured_providers(),
           step: :choose_kind,
           selected_kind: nil,
           oauth_setup: nil,
           smtp_form: empty_smtp_form(account),
           smtp_error: nil,
           smtp_notice: nil,
           smtp_busy: false
         )}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("choose-kind", %{"kind" => kind}, socket) when kind in @oauth_providers do
    if kind in socket.assigns.configured_providers do
      case Connectors.oauth_method_setup(socket.assigns.account.id, kind, :send) do
        {:ok, setup} ->
          {:noreply,
           assign(socket,
             step: :oauth_confirm,
             selected_kind: kind,
             oauth_setup: setup
           )}

        {:error, _reason} ->
          {:noreply,
           put_flash(socket, :error, "#{oauth_provider_label(kind)} setup is unavailable.")}
      end
    else
      {:noreply, put_flash(socket, :error, "#{oauth_provider_label(kind)} is not configured.")}
    end
  end

  def handle_event("choose-kind", %{"kind" => "smtp"}, socket) do
    {:noreply,
     assign(socket,
       step: :smtp_form,
       smtp_form: empty_smtp_form(socket.assigns.account),
       smtp_error: nil,
       smtp_notice: nil
     )}
  end

  def handle_event(
        "add-oauth-method",
        _params,
        %{assigns: %{oauth_setup: %{state: :add}, selected_kind: kind}} = socket
      )
      when kind in @oauth_providers do
    case Connectors.add_authorized_oauth_method(socket.assigns.account.id, kind, :send) do
      {:ok, _method} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{oauth_provider_label(kind)} send method added and enabled.")
         |> push_navigate(to: ~p"/settings/accounts/#{socket.assigns.account.id}")}

      {:error, _reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "The #{oauth_provider_label(kind)} send method could not be added."
         )}
    end
  end

  def handle_event("add-oauth-method", _params, socket), do: {:noreply, socket}

  def handle_event("back", _params, %{assigns: %{smtp_busy: false}} = socket) do
    {:noreply,
     assign(socket,
       step: :choose_kind,
       selected_kind: nil,
       oauth_setup: nil,
       smtp_form: empty_smtp_form(socket.assigns.account),
       smtp_error: nil,
       smtp_notice: nil
     )}
  end

  def handle_event("back", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("validate-smtp", %{"smtp" => params}, socket) do
    if socket.assigns.smtp_busy do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket, smtp_form: to_form(params, as: :smtp), smtp_error: nil, smtp_notice: nil)}
    end
  end

  def handle_event("test-smtp", _params, %{assigns: %{smtp_busy: false}} = socket) do
    params = form_params(socket.assigns.smtp_form)
    attrs = smtp_attrs(params, socket)

    socket =
      socket
      |> assign(smtp_busy: true, smtp_error: nil, smtp_notice: nil)
      |> start_async(:test_smtp, fn -> Connectors.test_smtp_connection(attrs) end)

    {:noreply, socket}
  end

  def handle_event("test-smtp", _params, socket), do: {:noreply, socket}

  def handle_event(
        "save-smtp",
        %{"smtp" => params},
        %{assigns: %{smtp_busy: false}} = socket
      ) do
    attrs = smtp_attrs(params, socket)

    socket =
      socket
      |> assign(
        smtp_busy: true,
        smtp_form: to_form(params, as: :smtp),
        smtp_error: nil,
        smtp_notice: nil
      )
      |> start_async(:save_smtp, fn -> Connectors.create_smtp_send_method(attrs) end)

    {:noreply, socket}
  end

  def handle_event("save-smtp", _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_async(:test_smtp, {:ok, :ok}, socket) do
    Process.send_after(self(), :unlock_smtp_busy, 1_000)

    {:noreply,
     assign(socket,
       smtp_notice: "Connection succeeded.",
       smtp_error: nil
     )}
  end

  def handle_async(:test_smtp, {:ok, {:error, reason}}, socket) do
    Process.send_after(self(), :unlock_smtp_busy, 1_000)
    {:noreply, assign(socket, smtp_error: format_error(reason), smtp_notice: nil)}
  end

  def handle_async(:test_smtp, {:exit, _reason}, socket) do
    Process.send_after(self(), :unlock_smtp_busy, 1_000)
    {:noreply, assign(socket, smtp_error: "Something went wrong.", smtp_notice: nil)}
  end

  def handle_async(:save_smtp, {:ok, {:ok, _method}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "SMTP send method added and enabled.")
     |> push_navigate(to: ~p"/settings/accounts/#{socket.assigns.account.id}")}
  end

  def handle_async(:save_smtp, {:ok, {:error, reason}}, socket) do
    Process.send_after(self(), :unlock_smtp_busy, 1_000)
    {:noreply, assign(socket, smtp_error: format_error(reason), smtp_notice: nil)}
  end

  def handle_async(:save_smtp, {:exit, _reason}, socket) do
    Process.send_after(self(), :unlock_smtp_busy, 1_000)
    {:noreply, assign(socket, smtp_error: "Something went wrong.", smtp_notice: nil)}
  end

  @impl Phoenix.LiveView
  def handle_info(:unlock_smtp_busy, socket) do
    {:noreply, assign(socket, smtp_busy: false)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>Add send method</h1>
          <p class="settings-intro">
            Connect a provider that sends mail for {@account.name || @account.local_part} ({@address}).
          </p>
        </div>
        <div class="settings-heading-actions">
          <.link navigate={~p"/settings/accounts/#{@account.id}"} class="settings-action">
            Cancel
          </.link>
        </div>
      </div>

      <div class="add-account-panel" id="add-send-method-panel">
        <div :if={@step == :choose_kind}>
          <div class="add-account-panel-header">
            <div>
              <p class="add-account-step">Step 1</p>
              <h2>Choose send method</h2>
            </div>
          </div>

          <div class="add-account-choices">
            <button
              id="send-method-gmail"
              type="button"
              class="add-account-choice"
              phx-click="choose-kind"
              phx-value-kind="gmail"
              disabled={"gmail" not in @configured_providers}
            >
              <.dm_mdi name="gmail" />
              <span>
                <strong>Gmail</strong>
                <small>
                  {if "gmail" in @configured_providers,
                    do: "Send through the Gmail API",
                    else: "Provider not configured"}
                </small>
              </span>
            </button>
            <button
              id="send-method-microsoft"
              type="button"
              class="add-account-choice"
              phx-click="choose-kind"
              phx-value-kind="microsoft"
              disabled={"microsoft" not in @configured_providers}
            >
              <.dm_mdi name="microsoft" />
              <span>
                <strong>Microsoft 365</strong>
                <small>
                  {if "microsoft" in @configured_providers,
                    do: "Send through Microsoft Graph",
                    else: "Provider not configured"}
                </small>
              </span>
            </button>
            <button
              id="send-method-smtp"
              type="button"
              class="add-account-choice"
              phx-click="choose-kind"
              phx-value-kind="smtp"
            >
              <.dm_mdi name="email-outline" />
              <span>
                <strong>SMTP</strong>
                <small>Host, port, username, and password</small>
              </span>
            </button>
          </div>
        </div>

        <div :if={@step == :oauth_confirm}>
          <div class="add-account-panel-header">
            <div>
              <p class="add-account-step">Step 2</p>
              <h2>{oauth_heading(@selected_kind, @oauth_setup.state)}</h2>
            </div>
          </div>
          <p class="settings-intro">
            Authorize {oauth_provider_label(@selected_kind)} to send mail for this account.
          </p>
          <div class="add-account-panel-footer">
            <button type="button" class="settings-action" phx-click="back">Back</button>
            <.link
              :if={@oauth_setup.state in [:connect, :upgrade, :reconnect]}
              id="oauth-method-action"
              href={~p"/connectors/#{@selected_kind}/start?account_id=#{@account.id}&purpose=send"}
              class="settings-action settings-action-primary"
            >
              {oauth_action(@selected_kind, @oauth_setup.state)}
            </.link>
            <button
              :if={@oauth_setup.state == :add}
              id="oauth-method-action"
              type="button"
              class="settings-action settings-action-primary"
              phx-click="add-oauth-method"
            >
              {oauth_action(@selected_kind, @oauth_setup.state)}
            </button>
            <button
              :if={@oauth_setup.state == :connected}
              id="oauth-method-action"
              type="button"
              class="settings-action settings-action-primary"
              disabled
            >
              {oauth_action(@selected_kind, @oauth_setup.state)}
            </button>
          </div>
        </div>

        <div :if={@step == :smtp_form}>
          <div class="add-account-panel-header">
            <div>
              <p class="add-account-step">Step 2</p>
              <h2>SMTP settings</h2>
            </div>
          </div>
          <p :if={@smtp_error} class="settings-error">{@smtp_error}</p>
          <p :if={@smtp_notice} class="settings-success">{@smtp_notice}</p>
          <.form
            for={@smtp_form}
            id="smtp-send-method-form"
            phx-change="validate-smtp"
            phx-submit="save-smtp"
          >
            <label>
              Email
              <input
                type="email"
                name={@smtp_form[:email_address].name}
                value={@smtp_form[:email_address].value}
                required
              />
            </label>
            <label>
              Host
              <input
                type="text"
                name={@smtp_form[:host].name}
                value={@smtp_form[:host].value}
                required
              />
            </label>
            <label>
              Port
              <input
                type="number"
                name={@smtp_form[:port].name}
                value={@smtp_form[:port].value}
                required
              />
            </label>
            <label>
              TLS mode
              <select name={@smtp_form[:tls_mode].name}>
                <option value="tls" selected={@smtp_form[:tls_mode].value in ["tls", "ssl"]}>
                  SSL/TLS (Implicit TLS)
                </option>
                <option value="starttls" selected={@smtp_form[:tls_mode].value == "starttls"}>
                  STARTTLS
                </option>
              </select>
            </label>
            <label>
              Username
              <input
                type="text"
                name={@smtp_form[:username].name}
                value={@smtp_form[:username].value}
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
                name={@smtp_form[:password].name}
                value={@smtp_form[:password].value}
                required
                autocomplete="current-password"
              />
            </label>
            <div class="add-account-panel-footer">
              <button type="button" class="settings-action" phx-click="back" disabled={@smtp_busy}>
                Back
              </button>
              <button
                type="button"
                id="test-smtp-connection"
                class="settings-action"
                phx-click="test-smtp"
                phx-disable-with="Testing…"
                disabled={@smtp_busy}
              >
                Test connection
              </button>
              <button
                type="submit"
                class="settings-action settings-action-primary"
                phx-disable-with="Saving…"
                disabled={@smtp_busy}
              >
                Save SMTP
              </button>
            </div>
          </.form>
        </div>
      </div>
    </section>
    """
  end

  defp smtp_attrs(params, socket) do
    params
    |> Map.put("account_id", socket.assigns.account.id)
    |> Map.put_new("email_address", socket.assigns.address)
  end

  defp form_params(form) do
    %{
      "email_address" => form[:email_address].value,
      "host" => form[:host].value,
      "port" => form[:port].value,
      "tls_mode" => form[:tls_mode].value,
      "username" => form[:username].value,
      "password" => form[:password].value
    }
  end

  defp empty_smtp_form(account) do
    address = Accounts.account_address(account)

    to_form(
      %{
        "email_address" => address,
        "host" => "",
        "port" => "465",
        "tls_mode" => "tls",
        "username" => address,
        "password" => ""
      },
      as: :smtp
    )
  end

  defp oauth_heading("microsoft", :connect), do: "Connect Microsoft"
  defp oauth_heading("microsoft", :upgrade), do: "Upgrade Microsoft access"
  defp oauth_heading("microsoft", :add), do: "Add Microsoft Send"
  defp oauth_heading("microsoft", :connected), do: "Microsoft Send connected"
  defp oauth_heading("microsoft", :reconnect), do: "Reconnect Microsoft"
  defp oauth_heading("gmail", :connect), do: "Connect Gmail"
  defp oauth_heading("gmail", :upgrade), do: "Upgrade Gmail access"
  defp oauth_heading("gmail", :add), do: "Add Gmail Send"
  defp oauth_heading("gmail", :connected), do: "Gmail Send connected"
  defp oauth_heading("gmail", :reconnect), do: "Reconnect Gmail"

  defp oauth_action("microsoft", state) when state in [:connect, :upgrade],
    do: "Continue with Microsoft"

  defp oauth_action("microsoft", :add), do: "Add Microsoft Send"
  defp oauth_action("microsoft", :connected), do: "Connected"
  defp oauth_action("microsoft", :reconnect), do: "Reconnect Microsoft"

  defp oauth_action("gmail", state) when state in [:connect, :upgrade],
    do: "Continue with Gmail"

  defp oauth_action("gmail", :add), do: "Add Gmail Send"
  defp oauth_action("gmail", :connected), do: "Connected"
  defp oauth_action("gmail", :reconnect), do: "Reconnect Gmail"

  defp oauth_provider_label("gmail"), do: "Gmail"
  defp oauth_provider_label("microsoft"), do: "Microsoft"

  defp format_error(%Error{message: message}), do: message
  defp format_error(%ProviderError{message: message}), do: message
  defp format_error(%Ecto.Changeset{}), do: "Invalid settings."
  defp format_error(_), do: "Something went wrong."
end

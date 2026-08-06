defmodule ManifoldWeb.AccountLive.SendMethodNew do
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
           page_title: "Add send method",
           account: account,
           address: Accounts.account_address(account),
           smtp_form: empty_smtp_form(account),
           smtp_error: nil,
           smtp_notice: nil,
           smtp_busy: false
         )}
    end
  end

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
            Configure SMTP submission for {@account.name || @account.local_part} ({@address}).
          </p>
        </div>
        <div class="settings-heading-actions">
          <.link navigate={~p"/settings/accounts/#{@account.id}"} class="settings-action">
            Cancel
          </.link>
        </div>
      </div>

      <div class="add-account-panel" id="add-send-method-panel">
        <div class="add-account-panel-header">
          <div>
            <p class="add-account-step">SMTP</p>
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
            <input type="text" name={@smtp_form[:host].name} value={@smtp_form[:host].value} required />
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
            <.link
              navigate={~p"/settings/accounts/#{@account.id}"}
              class="settings-action"
            >
              Cancel
            </.link>
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

  defp format_error(%Error{message: message}), do: message
  defp format_error(%ProviderError{message: message}), do: message
  defp format_error(%Ecto.Changeset{}), do: "Invalid settings."
  defp format_error(_), do: "Something went wrong."
end

defmodule ManifoldWeb.SettingsLive.MicrosoftDevice do
  use ManifoldWeb, :live_view
  alias Manifold.Accounts
  alias Manifold.Connectors.{DeviceOAuth, ProviderConfig}

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Microsoft device-code login",
        account: nil,
        device: nil,
        status: :idle,
        error: nil,
        timer: nil,
        request_ref: nil
      )

    purpose = Map.get(params, "purpose", "receive")

    with {:ok, id} <- Ecto.UUID.cast(id),
         account when not is_nil(account) <- Accounts.get_account(id),
         true <- account.active and is_nil(account.purge_requested_at),
         true <- purpose in ["receive", "send"],
         {:ok, resolved} <- ProviderConfig.fetch("microsoft"),
         "device_code" <- Keyword.get(resolved.config, :auth_flow) do
      {:ok,
       assign(socket,
         account: account,
         address: Accounts.account_address(account),
         purpose: purpose
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Microsoft device login is unavailable.")
         |> push_navigate(to: ~p"/settings/accounts")}
    end
  end

  @impl true
  def handle_event("start-device", _params, %{assigns: %{status: status}} = socket)
      when status in [:idle, :cancelled, :error] do
    account_id = socket.assigns.account.id
    purpose = socket.assigns.purpose
    ref = make_ref()

    {:noreply,
     socket
     |> clear_timer()
     |> assign(status: :starting, device: nil, error: nil, request_ref: ref)
     |> start_async({:start_device, ref}, fn -> DeviceOAuth.start(account_id, purpose) end)}
  end

  def handle_event("start-device", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-device", _params, socket) do
    result =
      if socket.assigns.device, do: DeviceOAuth.cancel(socket.assigns.device.id), else: {:ok, nil}

    case result do
      {:ok, _} ->
        {:noreply, socket |> clear_timer() |> assign(status: :cancelled, error: nil)}

      {:error, %{reason: :device_authorization_unavailable}} ->
        case DeviceOAuth.get(socket.assigns.device.id) do
          {:ok, %{status: "complete"}} ->
            {:noreply, connected(socket)}

          _ ->
            {:noreply, assign(socket, error: "Login could not be cancelled. Try again.")}
        end

      {:error, _} ->
        {:noreply, assign(socket, error: "Login could not be cancelled. Try again.")}
    end
  end

  @impl true
  def handle_async(
        {:start_device, ref},
        {:ok, {:ok, device}},
        %{assigns: %{request_ref: ref, status: :starting}} = socket
      ) do
    {:noreply, socket |> assign(device: device, status: :pending) |> schedule_poll()}
  end

  def handle_async({:start_device, _ref}, {:ok, {:ok, device}}, socket) do
    DeviceOAuth.cancel(device.id)
    {:noreply, socket}
  end

  def handle_async(
        {:start_device, ref},
        result,
        %{assigns: %{request_ref: ref, status: :starting}} = socket
      ),
      do: {:noreply, fail(socket, result)}

  def handle_async(
        {:poll_device, id},
        result,
        %{assigns: %{device: %{id: id}, status: :polling}} = socket
      ) do
    case result do
      {:ok, {:pending, device}} ->
        {:noreply, socket |> assign(device: device, status: :pending) |> schedule_poll()}

      {:ok, {:ok, _method}} ->
        {:noreply, connected(socket)}

      other ->
        {:noreply, fail(socket, other)}
    end
  end

  def handle_async(_name, _result, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:poll_device, id}, %{assigns: %{device: %{id: id}, status: :pending}} = socket) do
    {:noreply,
     socket
     |> clear_timer()
     |> assign(status: :polling)
     |> start_async({:poll_device, id}, fn -> DeviceOAuth.poll(id) end)}
  end

  def handle_info({:poll_device, _id}, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <section :if={@account} aria-labelledby="microsoft-device-title">
      <h1 id="microsoft-device-title">Microsoft device-code login</h1>
      <p>Connect Microsoft {@purpose} for {@address}.</p>
      <.dm_card class="oauth-provider-card" variant="bordered" shadow="sm">
        <p>No callback URL or client secret is needed. Your browser can be on another device.</p>
        <p :if={@status == :starting} role="status">Requesting a login code…</p>
        <div :if={@device && @status in [:pending, :polling]}>
          <p>Open Microsoft's website and enter this user code:</p>
          <.dm_input
            id="microsoft-device-user-code"
            name="user_code"
            label="User code"
            value={@device.user_code}
            readonly
          />
          <a
            id="microsoft-device-verification"
            href={@device.verification_uri}
            target="_blank"
            rel="noopener noreferrer"
            class="settings-action"
          >
            Open Microsoft login (opens in a new tab)
          </a>
          <p role="status" aria-live="polite">Waiting for Microsoft approval…</p>
          <p class="settings-secondary">
            This code expires at {DateTime.to_iso8601(@device.expires_at)}.
          </p>
        </div>
        <p :if={@status == :cancelled} role="status">
          Login cancelled. Start again to request a new code.
        </p>
        <p :if={@error} role="alert">{@error}</p>
        <button
          :if={@status in [:idle, :cancelled, :error]}
          id="start-microsoft-device"
          type="button"
          class="settings-action settings-action-primary"
          phx-click="start-device"
        >Start Microsoft login</button>
        <button
          :if={@status in [:starting, :pending, :polling]}
          id="cancel-microsoft-device"
          type="button"
          class="settings-action"
          phx-click="cancel-device"
        >Cancel login</button>
        <.link navigate={~p"/settings/accounts/#{@account.id}"} class="settings-action">Back to account</.link>
      </.dm_card>
    </section>
    """
  end

  defp schedule_poll(socket) do
    delay = max(socket.assigns.device.poll_after_seconds, 1) * 1_000

    assign(socket,
      timer: Process.send_after(self(), {:poll_device, socket.assigns.device.id}, delay)
    )
  end

  defp connected(socket) do
    socket
    |> clear_timer()
    |> put_flash(:info, "Microsoft #{socket.assigns.purpose} method connected.")
    |> push_navigate(to: ~p"/settings/accounts/#{socket.assigns.account.id}")
  end

  defp clear_timer(socket) do
    if socket.assigns.timer, do: Process.cancel_timer(socket.assigns.timer)
    assign(socket, timer: nil)
  end

  defp fail(socket, result) do
    message =
      case result do
        {:ok, {:error, %{reason: :device_authorization_expired}}} ->
          "This login code expired. Start again."

        {:ok, {:error, %{reason: :provider_configuration_changed}}} ->
          "Microsoft settings changed. Start a new login."

        {:ok, {:error, %{reason: :provider_address_mismatch}}} ->
          "Sign in with the Microsoft account matching this account's email address."

        _ ->
          "Microsoft login could not be completed. Check the application settings and try again."
      end

    socket |> clear_timer() |> assign(status: :error, error: message)
  end
end

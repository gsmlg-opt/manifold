defmodule ManifoldWeb.SettingsLive.GoogleLogin do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts
  alias Manifold.Connectors
  alias Manifold.Connectors.{OAuth, ProviderConfig}

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    socket =
      assign(socket,
        page_title: "Google login",
        account: nil,
        authorization: nil,
        status: :idle,
        error: nil,
        callback_form: callback_form(),
        form_revision: 0
      )

    purpose = Map.get(params, "purpose", "receive")

    with {:ok, id} <- Ecto.UUID.cast(id),
         account when not is_nil(account) <- Accounts.get_account(id),
         true <- account.active and is_nil(account.purge_requested_at),
         true <- purpose in ["receive", "send"],
         {:ok, resolved} <- ProviderConfig.fetch("gmail") do
      {:ok,
       assign(socket,
         account: account,
         address: Accounts.account_address(account),
         purpose: purpose,
         callback_url: resolved.callback_url || fallback_callback()
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Google login is unavailable.")
         |> push_navigate(to: ~p"/settings/accounts")}
    end
  end

  @impl true
  def handle_event("start-google", _params, %{assigns: %{status: status}} = socket)
      when status != :completing do
    case OAuth.start("gmail", socket.assigns.account.id, fallback_callback(),
           purpose: socket.assigns.purpose
         ) do
      {:ok, authorization} ->
        callback_url =
          authorization.url
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()
          |> Map.fetch!("redirect_uri")

        {:noreply,
         assign(socket,
           authorization: authorization,
           callback_url: callback_url,
           status: :pending,
           error: nil,
           callback_form: callback_form()
         )}

      {:error, _} ->
        {:noreply,
         assign(socket,
           authorization: nil,
           status: :idle,
           error: "Google login could not be started. Check OAuth settings and try again."
         )}
    end
  end

  def handle_event(
        "complete-google",
        %{"oauth_callback" => %{"callback_response_url" => url}},
        %{assigns: %{status: :pending, authorization: authorization}} = socket
      )
      when is_binary(url) do
    case OAuth.consume_callback_url("gmail", url, authorization.state, socket.assigns.account.id,
           purpose: socket.assigns.purpose
         ) do
      {:ok, code, consumed} ->
        {:noreply,
         socket
         |> assign(
           status: :completing,
           authorization: nil,
           error: nil,
           callback_form: callback_form()
         )
         |> start_async(:complete_google, fn ->
           Connectors.complete_authorization("gmail", code, consumed)
         end)}

      {:error, _} ->
        {:noreply,
         assign(socket,
           callback_form: callback_form(),
           form_revision: socket.assigns.form_revision + 1,
           error:
             "This callback URL does not match a valid Google login. Paste the full URL from this attempt, or start again."
         )}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:complete_google, {:ok, {:ok, _method}}, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Gmail #{socket.assigns.purpose} method connected.")
     |> push_navigate(to: ~p"/settings/accounts/#{socket.assigns.account.id}")}
  end

  def handle_async(:complete_google, _result, socket) do
    {:noreply,
     assign(socket,
       status: :idle,
       callback_form: callback_form(),
       error:
         "Google login could not be completed. Sign in with the Google account matching this account's email address and start again."
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section :if={@account} aria-labelledby="google-login-title">
      <h1 id="google-login-title">Google login</h1>
      <p>Connect Gmail {@purpose} for {@address}.</p>
      <.dm_card class="oauth-provider-card" variant="bordered" shadow="sm">
        <p>Keep this page open while signing in to Google in a new tab.</p>
        <p>
          After approving access, copy the complete URL from that tab's address bar and paste it
          below. You can copy it even if the localhost callback page cannot be reached.
        </p>
        <.dm_input
          id="google-login-callback"
          name="registered_callback"
          label="Registered callback URL"
          value={@callback_url}
          readonly
          helper="Register this exact URL in your Google Cloud OAuth client."
        />
        <div :if={@status == :pending}>
          <a
            id="google-login-link"
            href={@authorization.url}
            target="_blank"
            rel="noopener noreferrer"
            class="settings-action"
          >Open Google login (opens in a new tab)</a>
          <.form
            for={@callback_form}
            id="google-callback-form"
            phx-submit="complete-google"
            class="mailbox-setup-form"
          >
            <div id={"google-callback-entry-#{@form_revision}"}>
              <.dm_input
                id="google-callback-response"
                field={@callback_form[:callback_response_url]}
                type="url"
                label="Final Google redirect URL"
                value=""
                autocomplete="off"
                required
                helper="Paste the full URL, including code and state. Do not share it."
              />
            </div>
            <button
              id="complete-google-login"
              type="submit"
              class="settings-action settings-action-primary"
            >Complete Google login</button>
          </.form>
        </div>
        <p :if={@status == :completing} role="status">Completing Google login…</p>
        <p :if={@error} role="alert">{@error}</p>
        <button
          :if={@status != :completing}
          id="start-google-login"
          type="button"
          class={
            if @status == :pending,
              do: "settings-action",
              else: "settings-action settings-action-primary"
          }
          phx-click="start-google"
        >{if @status == :pending, do: "Start again", else: "Start Google login"}</button>
        <.link navigate={~p"/settings/accounts/#{@account.id}"} class="settings-action">Back to account</.link>
      </.dm_card>
    </section>
    """
  end

  defp callback_form, do: to_form(%{"callback_response_url" => ""}, as: :oauth_callback)
  defp fallback_callback, do: ManifoldWeb.Endpoint.url() <> "/connectors/gmail/callback"
end

defmodule ManifoldWeb.AccountLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.AccountLifecycle
  alias Manifold.Accounts
  alias Manifold.Connectors

  @refresh_interval 5_000
  @deleting_statuses ~w(requested running)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Accounts",
        accounts: [],
        delete_account: nil,
        delete_confirmation: "",
        delete_error: nil,
        refresh_timer: nil,
        refresh_token: nil
      )
      |> reload_accounts()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("disable-account", %{"id" => account_id}, socket) do
    with {:ok, account_id} <- cast_account_id(account_id),
         {:ok, _account} <- AccountLifecycle.disable_account(account_id) do
      {:noreply, reload_accounts(socket)}
    else
      _error -> {:noreply, put_flash(socket, :error, "Unable to disable this account.")}
    end
  end

  def handle_event("open-delete-account", %{"id" => account_id}, socket) do
    case fresh_delete_account(account_id) do
      {:ok, account} ->
        {:noreply,
         assign(socket,
           delete_account: account,
           delete_confirmation: "",
           delete_error: nil
         )}

      :error ->
        {:noreply,
         socket
         |> reload_accounts()
         |> put_flash(:error, "Account not found.")}
    end
  end

  def handle_event("validate-delete-account", %{"confirmation" => confirmation}, socket) do
    {:noreply, refresh_delete_dialog(socket, confirmation, nil)}
  end

  def handle_event("cancel-delete-account", _params, socket) do
    {:noreply, close_delete_dialog(socket)}
  end

  def handle_event("confirm-delete-account", %{"confirmation" => confirmation}, socket) do
    case socket.assigns.delete_account do
      %{id: account_id} ->
        case AccountLifecycle.request_deletion(account_id, confirmation) do
          {:ok, _purge} ->
            socket =
              socket
              |> close_delete_dialog()
              |> reload_accounts()
              |> put_flash(:info, "Account deletion queued.")

            {:noreply, socket}

          {:error, :confirmation_mismatch} ->
            {:noreply,
             refresh_delete_dialog(
               socket,
               confirmation,
               "The confirmation address does not match."
             )}

          {:error, _reason} ->
            {:noreply,
             refresh_delete_dialog(
               socket,
               confirmation,
               "Unable to queue account deletion."
             )}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("retry-delete-account", %{"id" => account_id}, socket) do
    result =
      with {:ok, account_id} <- cast_account_id(account_id),
           %{status: "failed", purge_id: purge_id} <- lifecycle_state(account_id),
           {:ok, _purge} <- AccountLifecycle.retry_deletion(purge_id) do
        :ok
      else
        _error -> :error
      end

    case result do
      :ok ->
        socket =
          socket
          |> reload_accounts()
          |> put_flash(:info, "Account deletion retry queued.")

        {:noreply, socket}

      :error ->
        {:noreply,
         socket
         |> reload_accounts()
         |> put_flash(:error, "Unable to retry account deletion.")}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(
        {:refresh_accounts, token},
        %{assigns: %{refresh_timer: timer, refresh_token: token}} = socket
      )
      when is_reference(timer) and is_reference(token) do
    socket =
      socket
      |> clear_refresh_timer()
      |> reload_accounts()

    {:noreply, socket}
  end

  def handle_info({:refresh_accounts, _stale_token}, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>Accounts</h1>
          <p class="settings-intro">
            Local email identities and their receive methods.
          </p>
        </div>
        <div class="settings-heading-actions">
          <.link
            id="add-account-button"
            navigate={~p"/settings/accounts/new"}
            class="settings-action settings-action-primary"
          >
            <.dm_mdi name="plus" /> Add account
          </.link>
        </div>
      </div>

      <div class="table-scroll">
        <table id="accounts">
          <thead>
            <tr>
              <th>Name</th>
              <th>Address</th>
              <th>Active receive method</th>
              <th>Methods</th>
              <th><span class="sr-only">Actions</span></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @accounts} id={"account-#{row.account.id}"}>
              <td data-label="Name">
                <strong>{row.account.name || row.account.local_part}</strong>
              </td>
              <td data-label="Address">{row.address}</td>
              <td data-label="Active receive method">
                <span :if={!row.account.active} class="account-state account-state-disabled">
                  Disabled
                </span>
                <span :if={row.account.active && row.enabled_method}>
                  {kind_label(row.enabled_method.kind)}
                  <span class={"policy-state state-#{row.enabled_method.status}"}>
                    {String.capitalize(row.enabled_method.status)}
                  </span>
                </span>
                <span
                  :if={row.account.active && !row.enabled_method}
                  class="settings-secondary"
                >
                  None
                </span>
              </td>
              <td data-label="Methods">{length(row.methods)}</td>
              <td data-label="Actions">
                <span :if={deleting?(row)} class="account-delete-status" aria-live="polite">
                  Deleting...
                </span>

                <div :if={delete_failed?(row)} class="account-delete-failed">
                  <span>Delete failed</span>
                  <.dm_tooltip
                    id={"retry-delete-account-tooltip-#{row.account.id}"}
                    content="Retry account deletion"
                    position="left"
                  >
                    <button
                      id={"retry-delete-account-#{row.account.id}"}
                      type="button"
                      class="settings-icon-button settings-icon-button-danger"
                      phx-click="retry-delete-account"
                      phx-value-id={row.account.id}
                      aria-label="Retry account deletion"
                    >
                      <.dm_mdi name="restart" data-icon="restart" />
                    </button>
                  </.dm_tooltip>
                </div>

                <div :if={account_actions?(row)} class="account-actions">
                  <.dm_tooltip
                    id={"edit-account-tooltip-#{row.account.id}"}
                    content="Edit account"
                    position="left"
                  >
                    <.link
                      id={"edit-account-#{row.account.id}"}
                      navigate={~p"/settings/accounts/#{row.account.id}/edit"}
                      class="settings-icon-button"
                      aria-label="Edit account"
                    >
                      <.dm_mdi name="pencil-outline" data-icon="pencil-outline" />
                    </.link>
                  </.dm_tooltip>

                  <.dm_tooltip
                    id={"manage-account-tooltip-#{row.account.id}"}
                    content="Manage account"
                    position="left"
                  >
                    <.link
                      id={"manage-account-#{row.account.id}"}
                      navigate={~p"/settings/accounts/#{row.account.id}"}
                      class="settings-icon-button"
                      aria-label="Manage account"
                    >
                      <.dm_mdi name="cog-outline" data-icon="cog-outline" />
                    </.link>
                  </.dm_tooltip>

                  <.dm_tooltip
                    :if={row.account.active}
                    id={"disable-account-tooltip-#{row.account.id}"}
                    content="Disable account"
                    position="left"
                  >
                    <button
                      id={"disable-account-#{row.account.id}"}
                      type="button"
                      class="settings-icon-button"
                      phx-click="disable-account"
                      phx-value-id={row.account.id}
                      aria-label="Disable account"
                    >
                      <.dm_mdi name="account-off-outline" data-icon="account-off-outline" />
                    </button>
                  </.dm_tooltip>

                  <.dm_tooltip
                    id={"delete-account-tooltip-#{row.account.id}"}
                    content="Delete account"
                    position="left"
                    color="error"
                  >
                    <button
                      id={"delete-account-#{row.account.id}"}
                      type="button"
                      class="settings-icon-button settings-icon-button-danger"
                      phx-click={open_delete_dialog(row.account.id)}
                      aria-label="Delete account"
                    >
                      <.dm_mdi name="delete-outline" data-icon="delete-outline" />
                    </button>
                  </.dm_tooltip>
                </div>
              </td>
            </tr>
            <tr :if={@accounts == []}>
              <td colspan="5" class="settings-empty">No accounts yet.</td>
            </tr>
          </tbody>
        </table>
      </div>

      <.focus_wrap
        :if={@delete_account}
        id="delete-account-dialog"
        class="account-delete-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="delete-account-title"
        aria-describedby="delete-account-warning"
        phx-mounted={JS.focus(to: "#delete-account-confirmation")}
        phx-remove={JS.pop_focus()}
        phx-window-keydown="cancel-delete-account"
        phx-key="Escape"
      >
        <div class="account-delete-backdrop" phx-click="cancel-delete-account"></div>
        <div class="account-delete-dialog">
          <h2 id="delete-account-title">Delete account?</h2>
          <p class="account-delete-identity">
            <strong>{@delete_account.name || @delete_account.address}</strong>
            <span>{@delete_account.address}</span>
          </p>
          <p id="delete-account-warning">
            This permanently deletes this account's local methods, credentials, messages,
            drafts, sent mail, folders, attachments, and stored objects. Mail and accounts
            held by the remote provider are not deleted.
          </p>
          <.form
            for={%{}}
            id="delete-account-form"
            phx-change="validate-delete-account"
            phx-submit="confirm-delete-account"
          >
            <label for="delete-account-confirmation">
              Type {@delete_account.address} to confirm
            </label>
            <input
              id="delete-account-confirmation"
              name="confirmation"
              value={@delete_confirmation}
              autocomplete="off"
              aria-invalid={not is_nil(@delete_error)}
              aria-describedby={@delete_error && "delete-account-error"}
            />
            <p :if={@delete_error} id="delete-account-error" role="alert">{@delete_error}</p>
            <div class="account-delete-actions">
              <button type="button" phx-click="cancel-delete-account">Cancel</button>
              <button
                id="confirm-delete-account"
                type="submit"
                disabled={String.trim(@delete_confirmation) != @delete_account.address}
              >
                Delete local account data
              </button>
            </div>
          </.form>
        </div>
      </.focus_wrap>
    </section>
    """
  end

  defp load_accounts(socket) do
    accounts = Accounts.list_accounts()
    states = AccountLifecycle.states_by_mailbox(Enum.map(accounts, & &1.id))

    rows =
      Enum.map(accounts, fn account ->
        methods = Connectors.list_receive_methods_for_account(account.id)

        %{
          account: account,
          address: Accounts.account_address(account),
          methods: methods,
          enabled_method: Enum.find(methods, & &1.enabled),
          lifecycle_state: Map.get(states, account.id)
        }
      end)

    assign(socket, :accounts, rows)
  end

  defp reload_accounts(socket) do
    socket
    |> load_accounts()
    |> reconcile_refresh_timer()
  end

  defp reconcile_refresh_timer(socket) do
    should_poll? = connected?(socket) && Enum.any?(socket.assigns.accounts, &deleting?/1)
    timer? = is_reference(socket.assigns.refresh_timer)
    token? = is_reference(socket.assigns.refresh_token)
    polling? = timer? and token?

    cond do
      should_poll? and polling? ->
        socket

      should_poll? ->
        socket
        |> clear_refresh_timer()
        |> schedule_refresh()

      timer? or token? ->
        clear_refresh_timer(socket)

      true ->
        socket
    end
  end

  defp clear_refresh_timer(socket) do
    if is_reference(socket.assigns.refresh_timer) do
      Process.cancel_timer(socket.assigns.refresh_timer)
    end

    assign(socket, refresh_timer: nil, refresh_token: nil)
  end

  defp schedule_refresh(socket) do
    token = make_ref()
    timer = Process.send_after(self(), {:refresh_accounts, token}, @refresh_interval)

    assign(socket, refresh_timer: timer, refresh_token: token)
  end

  defp close_delete_dialog(socket) do
    assign(socket,
      delete_account: nil,
      delete_confirmation: "",
      delete_error: nil
    )
  end

  defp refresh_delete_dialog(socket, confirmation, error) do
    case socket.assigns.delete_account do
      %{id: account_id} ->
        case fresh_delete_account(account_id) do
          {:ok, account} ->
            assign(socket,
              delete_account: account,
              delete_confirmation: confirmation,
              delete_error: error
            )

          :error ->
            socket
            |> close_delete_dialog()
            |> reload_accounts()
            |> put_flash(:error, "Account not found.")
        end

      nil ->
        socket
    end
  end

  defp fresh_delete_account(account_id) do
    with {:ok, account_id} <- cast_account_id(account_id),
         account when not is_nil(account) <- Accounts.get_account(account_id) do
      {:ok,
       %{
         id: account.id,
         name: account.name,
         address: Accounts.account_address(account)
       }}
    else
      _error -> :error
    end
  end

  defp lifecycle_state(account_id) do
    account_id
    |> List.wrap()
    |> AccountLifecycle.states_by_mailbox()
    |> Map.get(account_id)
  end

  defp cast_account_id(account_id) do
    case Ecto.UUID.cast(account_id) do
      {:ok, cast_id} -> {:ok, cast_id}
      :error -> :error
    end
  end

  defp deleting?(%{lifecycle_state: %{status: status}}), do: status in @deleting_statuses
  defp deleting?(_row), do: false

  defp delete_failed?(%{lifecycle_state: %{status: "failed"}}), do: true
  defp delete_failed?(_row), do: false

  defp account_actions?(row), do: not deleting?(row) and not delete_failed?(row)

  defp open_delete_dialog(account_id) do
    JS.push("open-delete-account", value: %{id: account_id})
    |> JS.push_focus()
  end

  defp kind_label("gmail"), do: "Gmail"
  defp kind_label("microsoft"), do: "Microsoft Graph"
  defp kind_label("imap"), do: "IMAP"
  defp kind_label("pop3"), do: "POP3"
  defp kind_label("eas"), do: "EAS"
  defp kind_label("ews"), do: "EWS"
  defp kind_label(kind), do: kind
end

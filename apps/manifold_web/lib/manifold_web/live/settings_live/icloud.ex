defmodule ManifoldWeb.SettingsLive.ICloud do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts
  alias Manifold.Connectors.ICloud

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "iCloud",
       accounts: Accounts.list_active_accounts(),
       connections: ICloud.list_connections()
     )}
  end

  @impl true
  def handle_event(
        "attach",
        %{"assignment" => %{"connection_id" => id, "account_id" => account_id}},
        socket
      ) do
    result = with {:ok, _} <- Ecto.UUID.cast(account_id), do: ICloud.attach(id, account_id)

    case result do
      {:ok, connection} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "iCloud connection assigned. Review the Account's service settings and destinations."
         )
         |> push_navigate(to: ~p"/settings/accounts/#{connection.account_id}")}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Unable to assign this connection. Choose an active Account without an iCloud connection."
         )}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="icloud-settings" class="space-y-6">
      <div class="settings-heading">
        <div>
          <h1>iCloud</h1><p class="settings-intro">
            Contacts and Calendar are configured inside an Account.
          </p>
        </div><.dm_btn navigate={~p"/settings/accounts"} variant="primary">Manage Accounts</.dm_btn>
      </div>
      <p>
        Choose an existing Account or create a local Account before connecting iCloud. Its address can differ from the Apple Account.
      </p>
      <.dm_btn id="icloud-create-account" navigate={~p"/settings/accounts/new"} variant="outline">
        Create local Account
      </.dm_btn>
      <p :if={@connections == []} id="icloud-empty">
        No iCloud connections yet. Open an Account to configure Contacts and Calendar.
      </p>
      <article
        :for={connection <- @connections}
        id={"icloud-#{connection.id}"}
        class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-6 space-y-4"
      >
        <h2>{connection.apple_id}</h2>
        <.dm_btn
          :if={connection.account_id}
          id={"manage-icloud-#{connection.id}"}
          navigate={~p"/settings/accounts/#{connection.account_id}"}
          variant="outline"
        >
          Manage in Account
        </.dm_btn>
        <div :if={is_nil(connection.account_id)}>
          <p>
            Account assignment required. Synchronization is paused until you explicitly choose an Account.
          </p>
          <.form
            for={%{"account_id" => ""}}
            as={:assignment}
            id={"icloud-assign-#{connection.id}"}
            phx-submit="attach"
            class="space-y-4"
          >
            <input type="hidden" name="assignment[connection_id]" value={connection.id} />
            <.dm_select
              name="assignment[account_id]"
              id={"icloud-account-#{connection.id}"}
              label="Account"
              value=""
              options={[
                {"", "Choose an Account"}
                | Enum.map(@accounts, &{&1.id, Accounts.account_address(&1)})
              ]}
            />
            <.dm_btn type="submit" variant="outline">Assign to Account</.dm_btn>
          </.form>
        </div>
      </article>
    </section>
    """
  end
end

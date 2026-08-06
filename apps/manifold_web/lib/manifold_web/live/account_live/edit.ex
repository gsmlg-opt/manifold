defmodule ManifoldWeb.AccountLive.Edit do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts

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
           page_title: "Edit account",
           account: account,
           form: account_form(account)
         )}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"account" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :account))}
  end

  def handle_event("save", %{"account" => params}, socket) do
    case Accounts.update_account(socket.assigns.account, params) do
      {:ok, account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account updated.")
         |> push_navigate(to: ~p"/settings/accounts/#{account.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, form_from_error(params, changeset))}

      {:error, %Manifold.Core.Error{} = error} ->
        form =
          to_form(params,
            as: :account,
            action: :validate,
            errors: [address: {error.message, []}]
          )

        {:noreply, assign(socket, :form, form)}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>Edit account</h1>
          <p class="settings-intro">
            Update the display name and email address for this local identity.
          </p>
        </div>
        <div class="settings-heading-actions">
          <.link navigate={~p"/settings/accounts/#{@account.id}"} class="settings-action">
            Cancel
          </.link>
        </div>
      </div>

      <.form for={@form} id="account-form" phx-change="validate" phx-submit="save">
        <label>
          Name
          <input type="text" name={@form[:name].name} value={@form[:name].value} required />
        </label>
        <label>
          Address
          <input
            type="email"
            name={@form[:address].name}
            value={@form[:address].value}
            placeholder="you@example.com"
            required
          />
        </label>
        <p :if={error = List.first(@form[:address].errors || [])} class="settings-error">
          {elem(error, 0)}
        </p>
        <button type="submit" class="settings-action settings-action-primary">
          Save changes
        </button>
      </.form>
    </section>
    """
  end

  defp account_form(account) do
    to_form(
      %{
        "name" => account.name || "",
        "address" => Accounts.account_address(account)
      },
      as: :account
    )
  end

  defp form_from_error(params, changeset) do
    to_form(params,
      as: :account,
      action: :validate,
      errors: form_errors(changeset)
    )
  end

  defp form_errors(changeset) do
    Enum.map(changeset.errors, fn
      {:local_part, error} -> {:address, error}
      other -> other
    end)
  end
end

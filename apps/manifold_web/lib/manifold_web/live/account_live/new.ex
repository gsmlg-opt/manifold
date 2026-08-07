defmodule ManifoldWeb.AccountLive.New do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Add account",
       form: to_form(%{"name" => "", "address" => ""}, as: :account)
     )}
  end

  @impl Phoenix.LiveView
  def handle_event("validate", %{"account" => params}, socket) do
    {:noreply, assign(socket, :form, to_form(params, as: :account))}
  end

  def handle_event("save", %{"account" => params}, socket) do
    case Accounts.create_account(params) do
      {:ok, account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account created.")
         |> push_navigate(to: ~p"/settings/accounts/#{account.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :account))}

      {:error, %Manifold.Core.Error{} = error} ->
        form =
          %Manifold.Accounts.Schema.Account{}
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.add_error(:address, error.message)
          |> Map.put(:action, :insert)
          |> to_form(as: :account)

        {:noreply, assign(socket, :form, form)}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>Add account</h1>
          <p class="settings-intro">
            Create a local identity with a display name and email address.
          </p>
        </div>
        <div class="settings-heading-actions">
          <.link navigate={~p"/settings/accounts"} class="settings-action">Cancel</.link>
        </div>
      </div>

      <.form for={@form} id="account-form" phx-change="validate" phx-submit="save">
        <label>
          Name <input type="text" name={@form[:name].name} value={@form[:name].value} required />
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
          Create account
        </button>
      </.form>
    </section>
    """
  end
end

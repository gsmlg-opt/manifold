defmodule ManifoldWeb.ContactLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.Contacts
  alias Manifold.Accounts
  alias Manifold.Connectors.ICloud.Outbound
  alias Manifold.Data.Schema.Contact

  @value_fields ~w(emails phones addresses)
  @name_fields ~w(full_name given_name family_name organization notes)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Contacts",
       search: "",
       offset: 0,
       contacts: [],
       contact: nil,
       form: nil,
       form_values: %{},
       error: nil,
       accounts: Accounts.list_accounts()
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    contact =
      if params["id"], do: Contacts.get_contact(params["id"], include_deleted_conflicts: true)

    socket =
      socket
      |> assign(contact: contact, error: nil, form: nil)
      |> reload_contacts()

    cond do
      socket.assigns.live_action == :new ->
        {:noreply, edit_form(socket, %Contact{})}

      params["id"] && is_nil(contact) ->
        {:noreply,
         socket |> put_flash(:error, "Contact not found.") |> push_patch(to: ~p"/contacts")}

      socket.assigns.live_action == :edit && not editable?(contact) ->
        {:noreply,
         socket
         |> put_flash(:error, "This iCloud source is read-only. Make a local copy to edit it.")
         |> push_patch(to: ~p"/contacts/#{contact.id}")}

      socket.assigns.live_action == :edit ->
        {:noreply, edit_form(socket, contact)}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    {:noreply, socket |> assign(search: search, offset: 0) |> reload_contacts()}
  end

  def handle_event("page", %{"direction" => direction}, socket)
      when direction in ["previous", "next"] do
    offset = max(0, socket.assigns.offset + if(direction == "next", do: 50, else: -50))
    {:noreply, socket |> assign(:offset, offset) |> reload_contacts()}
  end

  def handle_event("validate", %{"contact" => params}, socket) do
    attrs = normalize_values(params, socket.assigns.form_values)

    {:noreply,
     assign(socket,
       form_values: attrs,
       form: to_form(attrs, as: :contact),
       error: nil
     )}
  end

  def handle_event("add-value", %{"field" => field}, socket) when field in @value_fields do
    values = Map.update(socket.assigns.form_values, field, [%{}], &(&1 ++ [%{}]))
    {:noreply, assign(socket, :form_values, values)}
  end

  def handle_event("remove-value", %{"field" => field, "index" => index}, socket)
      when field in @value_fields do
    case Integer.parse(index) do
      {index, ""} when index >= 0 ->
        values = Map.update!(socket.assigns.form_values, field, &List.delete_at(&1, index))
        {:noreply, assign(socket, :form_values, values)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("save", %{"contact" => params}, socket) do
    # Preserve labels/provider-specific metadata when editing a local multi-value entry.
    attrs = normalize_values(params, socket.assigns.form_values)

    result =
      if socket.assigns.contact,
        do: Contacts.update_contact(socket.assigns.contact.id, attrs),
        else: Contacts.create_contact(attrs)

    case result do
      {:ok, contact} ->
        {:noreply,
         socket
         |> put_flash(:info, "Contact saved.")
         |> push_patch(to: ~p"/contacts/#{contact.id}")}

      {:error, _} ->
        {:noreply,
         assign(socket,
           form_values: attrs,
           form: to_form(params, as: :contact),
           error: "Unable to save contact. Check the name and contact values."
         )}
    end
  end

  def handle_event("delete", _params, socket) do
    case socket.assigns.contact && Contacts.delete_contact(socket.assigns.contact.id) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Contact deleted.") |> push_patch(to: ~p"/contacts")}

      _ ->
        {:noreply, put_flash(socket, :error, "Unable to delete this contact.")}
    end
  end

  def handle_event("sync-preference", %{"preference" => %{"sync_to_icloud" => value}}, socket) do
    case socket.assigns.contact &&
           Contacts.update_contact(socket.assigns.contact.id, %{sync_to_icloud: value}) do
      {:ok, contact} ->
        {:noreply,
         socket
         |> assign(:contact, Contacts.get_contact(contact.id))
         |> reload_contacts()
         |> put_flash(:info, "Synchronization preference saved.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Unable to update synchronization preference.")}
    end
  end

  def handle_event("copy", %{"copy" => params}, socket) do
    case socket.assigns.contact && Contacts.copy_contact(socket.assigns.contact.id, params) do
      {:ok, contact} ->
        {:noreply,
         socket
         |> put_flash(:info, "Local copy saved.")
         |> push_patch(to: ~p"/contacts/#{contact.id}")}

      _ ->
        {:noreply, put_flash(socket, :error, "Unable to copy this contact.")}
    end
  end

  def handle_event("resolve", %{"choice" => choice}, socket) when choice in ["local", "remote"] do
    result =
      if socket.assigns.contact && socket.assigns.contact.resource_id,
        do:
          Outbound.resolve(
            socket.assigns.contact.resource_id,
            if(choice == "local", do: :local, else: :remote)
          )

    case result do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conflict choice saved.")
         |> push_patch(
           to:
             if(socket.assigns.contact.deleted_at && choice == "local",
               do: ~p"/contacts",
               else: ~p"/contacts/#{socket.assigns.contact.id}"
             )
         )}

      _ ->
        {:noreply,
         put_flash(socket, :error, "Unable to resolve this conflict. Synchronize and try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section id="contacts-page" class="space-y-6">
      <div class="settings-heading">
        <div>
          <h1>Contacts</h1><p class="settings-intro">
            Save contacts locally and synchronize selected Accounts with iCloud.
          </p>
        </div>
        <div class="settings-heading-actions">
          <.dm_btn
            id="new-contact"
            class="settings-action-primary"
            navigate={~p"/contacts/new"}
            variant="primary"
          >
            Add contact
          </.dm_btn>
        </div>
      </div>
      <.form for={%{}} id="contact-search" phx-change="search" phx-submit="search">
        <.dm_input
          name="search"
          id="contact-search-input"
          type="search"
          label="Search contacts"
          value={@search}
          phx-debounce="250"
        />
      </.form>
      <div class="grid gap-6 lg:grid-cols-2">
        <section
          aria-label="Contact list"
          class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-4"
        >
          <p :if={@contacts == []} id="contacts-empty">
            No contacts found. Add a contact or configure iCloud inside an Account.
          </p>
          <ul id="contacts-list" class="space-y-4">
            <li :for={contact <- @contacts} id={"contact-#{contact.id}"}>
              <.link patch={~p"/contacts/#{contact.id}"} class="text-primary font-semibold">{contact.full_name}</.link>
              <p class="text-sm text-on-surface-variant">{source(contact)}</p>
              <p :if={contact.deleted_at}>Deletion conflict</p>
              <p :for={email <- contact.emails}>{email["value"]}</p>
            </li>
          </ul>
          <div class="flex gap-4 mt-4">
            <.dm_btn
              id="contacts-previous"
              type="button"
              variant="ghost"
              phx-click="page"
              phx-value-direction="previous"
              disabled={@offset == 0}
            >
              Previous
            </.dm_btn>
            <.dm_btn
              id="contacts-next"
              type="button"
              variant="ghost"
              phx-click="page"
              phx-value-direction="next"
              disabled={length(@contacts) < 50}
            >
              Next
            </.dm_btn>
          </div>
        </section>
        <section
          :if={@form}
          id="contact-editor"
          aria-label="Contact editor"
          class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-4"
        >
          <h2>{if @contact, do: "Edit contact", else: "New contact"}</h2>
          <.form
            for={@form}
            id="contact-form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-4"
          >
            <.dm_input field={@form[:full_name]} label="Full name" required />
            <.dm_input field={@form[:given_name]} label="Given name" />
            <.dm_input field={@form[:family_name]} label="Family name" />
            <.dm_input field={@form[:organization]} label="Organization" />
            <.dm_select
              field={@form[:account_id]}
              label="Account"
              options={account_options(@accounts)}
              disabled={@contact && not is_nil(@contact.resource_id)}
            />
            <p :if={@contact && @contact.resource_id} class="text-on-surface-variant">
              To use another Account, make an explicit local copy.
            </p>
            <.dm_input field={@form[:sync_to_icloud]} type="checkbox" label="Sync to iCloud" />
            <p class="text-on-surface-variant">
              Saves commit locally first. Synchronization waits for a configured destination.
            </p>
            <fieldset :for={field <- ["emails", "phones"]} class="space-y-4">
              <legend>{String.capitalize(field)}</legend>
              <div :for={{value, index} <- Enum.with_index(@form_values[field])} class="space-y-2">
                <.dm_input
                  id={"#{field}-#{index}-value"}
                  name={"contact[#{field}][#{index}][value]"}
                  label={if field == "emails", do: "Email", else: "Phone"}
                  type={if field == "emails", do: "email", else: "tel"}
                  value={value["value"]}
                />
                <.dm_input
                  id={"#{field}-#{index}-label"}
                  name={"contact[#{field}][#{index}][label]"}
                  label="Label"
                  value={value["label"]}
                />
                <.dm_btn
                  id={"remove-#{field}-#{index}"}
                  type="button"
                  variant="ghost"
                  phx-click="remove-value"
                  phx-value-field={field}
                  phx-value-index={index}
                >
                  Remove
                </.dm_btn>
              </div>
              <.dm_btn
                id={"add-#{field}"}
                type="button"
                variant="outline"
                phx-click="add-value"
                phx-value-field={field}
              >
                Add {if field == "emails", do: "email", else: "phone"}
              </.dm_btn>
            </fieldset>
            <fieldset class="space-y-4">
              <legend>Postal addresses</legend>
              <div
                :for={{value, index} <- Enum.with_index(@form_values["addresses"])}
                class="space-y-2"
              >
                <.dm_input
                  :for={
                    {key, label} <- [
                      {"label", "Label"},
                      {"street", "Street"},
                      {"locality", "City"},
                      {"region", "State / region"},
                      {"postal_code", "Postal code"},
                      {"country", "Country"}
                    ]
                  }
                  id={"addresses-#{index}-#{key}"}
                  name={"contact[addresses][#{index}][#{key}]"}
                  label={label}
                  value={value[key]}
                />
                <.dm_btn
                  id={"remove-addresses-#{index}"}
                  type="button"
                  variant="ghost"
                  phx-click="remove-value"
                  phx-value-field="addresses"
                  phx-value-index={index}
                >
                  Remove address
                </.dm_btn>
              </div>
              <.dm_btn
                id="add-addresses"
                type="button"
                variant="outline"
                phx-click="add-value"
                phx-value-field="addresses"
              >
                Add address
              </.dm_btn>
            </fieldset>
            <.dm_input field={@form[:notes]} type="textarea" label="Notes" />
            <p :if={@error} role="alert" class="settings-error">{@error}</p>
            <div class="flex gap-4">
              <.dm_btn id="save-contact" variant="primary" type="submit">Save contact</.dm_btn>
              <.dm_btn
                patch={if @contact, do: ~p"/contacts/#{@contact.id}", else: ~p"/contacts"}
                variant="ghost"
              >
                Cancel
              </.dm_btn>
            </div>
          </.form>
        </section>
        <section
          :if={@contact && !@form}
          id="contact-detail"
          class="bg-surface-container text-on-surface border border-outline-variant rounded-lg p-4 space-y-4"
        >
          <h2>{@contact.full_name}</h2><p>{source(@contact)}</p>
          <p id="contact-sync-status" aria-live="polite">{sync_status(@contact)}</p>
          <.form
            :if={is_nil(@contact.deleted_at)}
            for={%{"sync_to_icloud" => @contact.sync_to_icloud}}
            as={:preference}
            id="contact-sync-preference"
            phx-submit="sync-preference"
          >
            <.dm_input
              name="preference[sync_to_icloud]"
              id="contact-sync-enabled"
              type="checkbox"
              value={@contact.sync_to_icloud}
              label="Sync to iCloud"
            />
            <.dm_btn type="submit" variant="outline">Save sync preference</.dm_btn>
          </.form>
          <p :if={@contact.deleted_at}>Local deletion is waiting for conflict resolution.</p>
          <p :if={!editable?(@contact)} id="contact-read-only">
            This iCloud source is read-only. Make a local copy to edit it.
          </p>
          <div :if={conflicted?(@contact)} id="contact-conflict" class="space-y-4">
            <p>Both your local draft and iCloud changed. Choose which version to keep.</p>
            <.dm_btn
              id="contact-use-local"
              phx-click="resolve"
              phx-value-choice="local"
              variant="outline"
            >
              Use local
            </.dm_btn>
            <.dm_btn
              id="contact-use-icloud"
              phx-click="resolve"
              phx-value-choice="remote"
              variant="outline"
            >
              Use iCloud
            </.dm_btn>
          </div>
          <dl class="space-y-4">
            <div
              :for={
                {label, value} <- [
                  {"Given name", @contact.given_name},
                  {"Family name", @contact.family_name},
                  {"Organization", @contact.organization}
                ]
              }
              :if={value}
            >
              <dt class="text-sm text-on-surface-variant">{label}</dt><dd>{value}</dd>
            </div>
            <div :for={email <- @contact.emails}>
              <dt>Email {email["label"]}</dt><dd>{email["value"]}</dd>
            </div>
            <div :for={phone <- @contact.phones}>
              <dt>Phone {phone["label"]}</dt><dd>{phone["value"]}</dd>
            </div>
            <div :for={address <- @contact.addresses}>
              <dt>Address {address["label"]}</dt><dd class="whitespace-pre-line">
                {address_text(address)}
              </dd>
            </div>
            <div :if={@contact.notes}>
              <dt>Notes</dt><dd class="whitespace-pre-wrap">{@contact.notes}</dd>
            </div>
          </dl>
          <div :if={editable?(@contact) && is_nil(@contact.deleted_at)} class="flex gap-4">
            <.dm_btn id="edit-contact" patch={~p"/contacts/#{@contact.id}/edit"} variant="outline">
              Edit contact
            </.dm_btn>
            <.dm_btn
              id="delete-contact"
              variant="error"
              confirm={
                if @contact.sync_to_icloud && @contact.resource_id,
                  do: "Delete this contact locally and queue its iCloud deletion?",
                  else: "Delete this local contact?"
              }
              confirm_title="Delete contact"
              phx-click="delete"
            >
              Delete contact
            </.dm_btn>
          </div>
          <.form
            :if={is_nil(@contact.deleted_at)}
            for={%{"account_id" => ""}}
            as={:copy}
            id="contact-copy-form"
            phx-submit="copy"
            class="space-y-4"
          >
            <.dm_select
              name="copy[account_id]"
              id="contact-copy-account"
              label="Copy to Account"
              options={account_options(@accounts)}
              value=""
            />
            <.dm_btn id="copy-contact" type="submit" variant="outline">Make local copy</.dm_btn>
          </.form>
        </section>
      </div>
    </section>
    """
  end

  defp reload_contacts(socket),
    do:
      assign(
        socket,
        :contacts,
        Contacts.list_contacts(
          search: socket.assigns.search,
          limit: 50,
          offset: socket.assigns.offset,
          include_deleted_conflicts: true
        )
      )

  defp edit_form(socket, contact) do
    values = Map.new(@name_fields, &{&1, Map.get(contact, String.to_existing_atom(&1)) || ""})

    values =
      values
      |> Map.put("account_id", contact.account_id || "")
      |> Map.put("sync_to_icloud", contact.sync_to_icloud)

    values =
      Enum.reduce(
        @value_fields,
        values,
        &Map.put(&2, &1, Map.get(contact, String.to_existing_atom(&1)) || [])
      )

    assign(socket, form_values: values, form: to_form(values, as: :contact))
  end

  defp normalize_values(params, previous) do
    attrs =
      Map.merge(
        Map.take(previous, ~w(account_id sync_to_icloud)),
        Map.take(params, @name_fields ++ ~w(account_id sync_to_icloud))
      )

    Enum.reduce(@value_fields, attrs, fn field, attrs ->
      values =
        case Map.get(params, field, %{}) do
          values when is_map(values) ->
            values
            |> Enum.flat_map(fn {key, value} ->
              case Integer.parse(key) do
                {index, ""} when index >= 0 and is_map(value) -> [{index, value}]
                _ -> []
              end
            end)
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.map(&elem(&1, 1))

          values when is_list(values) ->
            values
        end

      old_values = Map.get(previous, field, [])

      values =
        Enum.with_index(values)
        |> Enum.map(fn {value, index} -> Map.merge(Enum.at(old_values, index, %{}), value) end)

      Map.put(attrs, field, values)
    end)
  end

  defp source(%{collection_id: nil}), do: "Local contact"

  defp source(%{collection: collection}),
    do: "iCloud · #{collection.connection.apple_id} · #{collection.name}"

  defp account_options(accounts),
    do: [
      {"", "Local only — no Account"} | Enum.map(accounts, &{&1.id, Accounts.account_address(&1)})
    ]

  defp editable?(%{sync_to_icloud: false}), do: true
  defp editable?(%{collection_id: nil}), do: true

  defp editable?(%{collection: collection}),
    do: collection.can_update == true or (is_nil(collection.can_update) and collection.writable)

  defp conflicted?(%{resource: %{status: "conflict"}}), do: true
  defp conflicted?(_), do: false
  defp sync_status(%{sync_to_icloud: false}), do: "Sync to iCloud is off"
  defp sync_status(%{resource: %{status: status}}), do: status_label(status)
  defp sync_status(%{account_id: nil}), do: "Local only"
  defp sync_status(_), do: "Waiting for configuration"
  defp status_label("synced"), do: "Synchronized"
  defp status_label("uncertain"), do: "Syncing — confirming remote outcome"
  defp status_label(status), do: String.capitalize(status)

  defp address_text(address),
    do: Enum.map_join(~w(street locality region postal_code country), "\n", &(address[&1] || ""))
end

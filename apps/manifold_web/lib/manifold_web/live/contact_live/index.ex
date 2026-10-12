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
       account_id: nil,
       contact_groups: [],
       has_next: false,
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

    account_id =
      if Enum.any?(socket.assigns.accounts, &(&1.id == params["account"])),
        do: params["account"]

    offset = if account_id == socket.assigns.account_id, do: socket.assigns.offset, else: 0

    socket =
      socket
      |> assign(contact: contact, error: nil, form: nil, account_id: account_id, offset: offset)
      |> reload_contacts()

    cond do
      socket.assigns.live_action == :new ->
        {:noreply, edit_form(socket, %Contact{account_id: account_id})}

      params["id"] && is_nil(contact) ->
        {:noreply,
         socket
         |> put_flash(:error, "Contact not found.")
         |> push_patch(to: contact_path(nil, :index, socket.assigns.account_id))}

      socket.assigns.live_action == :edit && not editable?(contact) ->
        {:noreply,
         socket
         |> put_flash(:error, "This iCloud source is read-only. Make a local copy to edit it.")
         |> push_patch(to: contact_path(contact, :show, socket.assigns.account_id))}

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
         |> push_patch(to: contact_path(contact, :show, socket.assigns.account_id))}

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
         socket
         |> put_flash(:info, "Contact deleted.")
         |> push_patch(to: contact_path(nil, :index, socket.assigns.account_id))}

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
         |> push_patch(to: contact_path(contact, :show, socket.assigns.account_id))}

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
               do: contact_path(nil, :index, socket.assigns.account_id),
               else: contact_path(socket.assigns.contact, :show, socket.assigns.account_id)
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
    <section
      id="contacts-page"
      class={["contacts-workspace", (@contact || @form) && "contacts-workspace--detail-open"]}
    >
      <aside class="contacts-workspace__sources" aria-label="Contact sources">
        <div class="contacts-workspace__title">
          <.dm_mdi name="account-box-outline" class="contacts-workspace__title-icon" />
          <h1>Contacts</h1>
        </div>
        <.dm_btn
          id="new-contact"
          patch={contact_path(nil, :new, @account_id)}
          variant={if @form, do: "outline", else: "primary"}
          class="contacts-workspace__create"
        >
          <.dm_mdi name="plus" class="contacts-workspace__icon" /> New contact
        </.dm_btn>
        <nav class="contacts-workspace__source-nav" aria-label="Address books">
          <.link
            id="contacts-source-all"
            patch={~p"/contacts"}
            class={["contacts-workspace__source", is_nil(@account_id) && "is-active"]}
            aria-current={is_nil(@account_id) && "page"}
          >
            <.dm_mdi name="account-multiple-outline" class="contacts-workspace__icon" />
            <span>All contacts</span>
          </.link>
          <p :if={@accounts != []} class="contacts-workspace__nav-caption">Accounts</p>
          <.link
            :for={account <- @accounts}
            id={"contacts-source-#{account.id}"}
            patch={contact_path(nil, :index, account.id)}
            class={["contacts-workspace__source", @account_id == account.id && "is-active"]}
            aria-current={@account_id == account.id && "page"}
          >
            <.dm_mdi name="account-circle-outline" class="contacts-workspace__icon" />
            <span class="contacts-workspace__source-copy">
              <strong>{account.name || "Account"}</strong>
              <small>{Accounts.account_address(account)}</small>
            </span>
          </.link>
        </nav>
        <.link navigate={~p"/settings/accounts"} class="contacts-workspace__manage">
          <.dm_mdi name="cog-outline" class="contacts-workspace__icon" /> Manage accounts
        </.link>
      </aside>

      <section class="contacts-workspace__directory" aria-label="Contact list">
        <header class="contacts-workspace__directory-header">
          <div class="contacts-workspace__directory-heading">
            <h2>{account_heading(@account_id, @accounts)}</h2>
            <span>{if @contacts == [], do: "0", else: "#{@offset + 1}–#{@offset + length(@contacts)}"} shown</span>
          </div>
          <.form for={%{}} id="contact-search" phx-change="search" phx-submit="search">
            <.dm_input
              name="search"
              id="contact-search-input"
              type="search"
              label="Search contacts"
              placeholder="Search names, email, phone…"
              value={@search}
              phx-debounce="250"
            />
          </.form>
        </header>
        <div class="contacts-workspace__directory-scroll">
          <div :if={@contacts == []} id="contacts-empty" class="contacts-workspace__list-empty">
            <.dm_mdi name="account-search-outline" class="contacts-workspace__empty-icon" />
            <h3>{if @search == "", do: "Your contacts belong here", else: "No matching contacts"}</h3>
            <p>
              {if @search == "",
                do: "Add a contact or connect iCloud in account settings.",
                else: "Try another name, email address or phone number."}
            </p>
          </div>
          <ul id="contacts-list" class="contacts-workspace__groups">
            <li :for={{letter, contacts} <- @contact_groups} class="contacts-workspace__group">
              <h3 class="contacts-workspace__letter">{letter}</h3>
              <ul>
                <li :for={contact <- contacts} id={"contact-#{contact.id}"}>
                  <.link
                    patch={contact_path(contact, :show, @account_id)}
                    class={[
                      "contacts-workspace__row",
                      @contact && @contact.id == contact.id && "is-selected"
                    ]}
                    aria-current={@contact && @contact.id == contact.id && "true"}
                  >
                    <.dm_avatar
                      name={contact.full_name}
                      size="sm"
                      class="contacts-workspace__avatar"
                      aria-hidden="true"
                    />
                    <span class="contacts-workspace__row-copy">
                      <strong>{contact.full_name}</strong>
                      <small>{contact_subtitle(contact)}</small>
                    </span>
                    <span :if={contact.deleted_at} class="contacts-workspace__row-status">Deletion conflict</span>
                    <.dm_mdi
                      :if={!contact.deleted_at && contact.collection_id}
                      name="cloud-outline"
                      class="contacts-workspace__row-cloud"
                    />
                  </.link>
                </li>
              </ul>
            </li>
          </ul>
        </div>
        <footer class="contacts-workspace__pagination">
          <.dm_btn
            id="contacts-previous"
            type="button"
            variant="ghost"
            phx-click="page"
            phx-value-direction="previous"
            disabled={@offset == 0}
            aria-label="Previous contacts page"
          >
            <.dm_mdi name="chevron-left" class="contacts-workspace__icon" /> Previous
          </.dm_btn>
          <.dm_btn
            id="contacts-next"
            type="button"
            variant="ghost"
            phx-click="page"
            phx-value-direction="next"
            disabled={!@has_next}
            aria-label="Next contacts page"
          >
            Next <.dm_mdi name="chevron-right" class="contacts-workspace__icon" />
          </.dm_btn>
        </footer>
      </section>

      <section
        :if={!@contact && !@form}
        class="contacts-workspace__welcome"
        aria-label="Contact details"
      >
        <span class="contacts-workspace__welcome-mark"><.dm_mdi name="account-outline" /></span>
        <p class="contacts-workspace__eyebrow">A little more personal</p>
        <h2>Everyone,<br />in one place.</h2>
        <p>
          Select a contact to see their details.<br />Keep your people close, across local and iCloud accounts.
        </p>
      </section>

      <section
        :if={@form}
        id="contact-editor"
        aria-label="Contact editor"
        class="contacts-workspace__editor"
      >
        <header class="contacts-workspace__pane-header">
          <.dm_btn
            patch={contact_path(@contact, if(@contact, do: :show, else: :index), @account_id)}
            variant="ghost"
            class="contacts-workspace__back"
            aria-label="Back to contacts"
          >
            <.dm_mdi name="arrow-left" class="contacts-workspace__icon" /> Back
          </.dm_btn>
          <h2>{if @contact, do: "Edit contact", else: "New contact"}</h2>
          <p>A name, a number, a way to stay in touch.</p>
        </header>
        <.form
          for={@form}
          id="contact-form"
          phx-change="validate"
          phx-submit="save"
          class="contacts-workspace__edit-form"
        >
          <fieldset class="contacts-workspace__form-section">
            <legend>Profile</legend>
            <.dm_input field={@form[:full_name]} label="Full name" required />
            <div class="contacts-workspace__form-grid">
              <.dm_input field={@form[:given_name]} label="Given name" />
              <.dm_input field={@form[:family_name]} label="Family name" />
            </div>
            <.dm_input field={@form[:organization]} label="Organization" />
          </fieldset>
          <fieldset :for={field <- ["emails", "phones"]} class="contacts-workspace__form-section">
            <legend>{String.capitalize(field)}</legend>
            <div
              :for={{value, index} <- Enum.with_index(@form_values[field])}
              class="contacts-workspace__value-row"
            >
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
              <%!-- # TODO(upstream): duskmoon-dev/duskmoon-elements#86
              # WORKAROUND(upstream): duskmoon-dev/duskmoon-elements#86 — slotted text names the shadow button. --%>
              <.dm_btn
                id={"remove-#{field}-#{index}"}
                type="button"
                variant="ghost"
                phx-click="remove-value"
                phx-value-field={field}
                phx-value-index={index}
                aria-label={"Remove #{if field == "emails", do: "email", else: "phone"} #{index + 1}"}
              >
                <.dm_mdi name="close" class="contacts-workspace__icon" />
                <span class="sr-only">
                  {"Remove #{if field == "emails", do: "email", else: "phone"} #{index + 1}"}
                </span>
              </.dm_btn>
            </div>
            <.dm_btn
              id={"add-#{field}"}
              type="button"
              variant="ghost"
              phx-click="add-value"
              phx-value-field={field}
            >
              <.dm_mdi name="plus" class="contacts-workspace__icon" />
              Add {if field == "emails", do: "email", else: "phone"}
            </.dm_btn>
          </fieldset>
          <fieldset class="contacts-workspace__form-section">
            <legend>Postal addresses</legend>
            <div
              :for={{value, index} <- Enum.with_index(@form_values["addresses"])}
              class="contacts-workspace__address-fields"
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
              variant="ghost"
              phx-click="add-value"
              phx-value-field="addresses"
            >
              <.dm_mdi name="plus" class="contacts-workspace__icon" /> Add address
            </.dm_btn>
          </fieldset>
          <fieldset class="contacts-workspace__form-section">
            <legend>Notes</legend>
            <.dm_input field={@form[:notes]} type="textarea" label="Notes" />
          </fieldset>
          <fieldset class="contacts-workspace__form-section">
            <legend>Account & synchronization</legend>
            <.dm_select
              field={@form[:account_id]}
              label="Account"
              options={account_options(@accounts)}
              disabled={@contact && not is_nil(@contact.resource_id)}
            />
            <p :if={@contact && @contact.resource_id} class="contacts-workspace__hint">
              To use another Account, make an explicit local copy.
            </p>
            <.dm_input field={@form[:sync_to_icloud]} type="checkbox" label="Sync to iCloud" />
            <p class="contacts-workspace__hint">
              Saved locally first. iCloud sync runs in the background when a destination is configured.
            </p>
          </fieldset>
          <p :if={@error} role="alert" class="settings-error">{@error}</p>
          <footer class="contacts-workspace__form-actions">
            <.dm_btn
              patch={contact_path(@contact, if(@contact, do: :show, else: :index), @account_id)}
              variant="ghost"
            >
              Cancel
            </.dm_btn>
            <.dm_btn id="save-contact" variant="primary" type="submit">Save contact</.dm_btn>
          </footer>
        </.form>
      </section>

      <section
        :if={@contact && !@form}
        id="contact-detail"
        class="contacts-workspace__detail"
        aria-label="Contact details"
      >
        <header class="contacts-workspace__detail-toolbar">
          <.dm_btn
            patch={contact_path(nil, :index, @account_id)}
            variant="ghost"
            class="contacts-workspace__back"
            aria-label="Back to contacts"
          >
            <.dm_mdi name="arrow-left" class="contacts-workspace__icon" /> Contacts
          </.dm_btn>
          <.dm_btn
            :if={editable?(@contact) && is_nil(@contact.deleted_at)}
            id="edit-contact"
            patch={contact_path(@contact, :edit, @account_id)}
            variant="outline"
          >
            <.dm_mdi name="pencil-outline" class="contacts-workspace__icon" /> Edit contact
          </.dm_btn>
        </header>
        <div class="contacts-workspace__profile">
          <.dm_avatar
            name={@contact.full_name}
            size="2xl"
            class="contacts-workspace__profile-avatar"
            aria-hidden="true"
          />
          <h2>{@contact.full_name}</h2>
          <p :if={@contact.organization} class="contacts-workspace__organization">
            {@contact.organization}
          </p>
          <p class="contacts-workspace__source-label">{source(@contact)}</p>
          <span id="contact-sync-status" class="contacts-workspace__sync-status" aria-live="polite">
            <.dm_mdi
              name={if @contact.sync_to_icloud, do: "cloud-outline", else: "cloud-off-outline"}
              class="contacts-workspace__icon"
            /> {sync_status(@contact)}
          </span>
        </div>
        <div class="contacts-workspace__detail-body">
          <div :if={conflicted?(@contact)} id="contact-conflict" class="contacts-workspace__notice">
            <strong>Choose which version to keep</strong>
            <p>Both your local draft and iCloud changed.</p>
            <p :if={@contact.deleted_at}>Local deletion is waiting for conflict resolution.</p>
            <div class="contacts-workspace__notice-actions">
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
          </div>
          <p :if={!editable?(@contact)} id="contact-read-only" class="contacts-workspace__notice">
            This iCloud source is read-only. Make a local copy to edit it.
          </p>
          <dl class="contacts-workspace__fields">
            <div :for={email <- @contact.emails} class="contacts-workspace__field">
              <dt>
                <.dm_mdi name="email-outline" class="contacts-workspace__icon" /><span>Email
                <small>{email["label"]}</small></span>
              </dt>
              <dd><a href={"mailto:#{email["value"]}"}>{email["value"]}</a></dd>
            </div>
            <div :for={phone <- @contact.phones} class="contacts-workspace__field">
              <dt>
                <.dm_mdi name="phone-outline" class="contacts-workspace__icon" /><span>Phone
                <small>{phone["label"]}</small></span>
              </dt>
              <dd><a href={"tel:#{phone["value"]}"}>{phone["value"]}</a></dd>
            </div>
            <div :for={address <- @contact.addresses} class="contacts-workspace__field">
              <dt>
                <.dm_mdi name="map-marker-outline" class="contacts-workspace__icon" /><span>Address
                <small>{address["label"]}</small></span>
              </dt>
              <dd class="contacts-workspace__multiline">{address_text(address)}</dd>
            </div>
            <div
              :for={
                {label, value} <- [
                  {"Given name", @contact.given_name},
                  {"Family name", @contact.family_name}
                ]
              }
              :if={value && value != ""}
              class="contacts-workspace__field"
            >
              <dt>{label}</dt><dd>{value}</dd>
            </div>
            <div
              :if={@contact.notes && @contact.notes != ""}
              class="contacts-workspace__field contacts-workspace__field--notes"
            >
              <dt><.dm_mdi name="text-box-outline" class="contacts-workspace__icon" /> Notes</dt><dd class="contacts-workspace__multiline">
                {@contact.notes}
              </dd>
            </div>
          </dl>
          <details
            :if={is_nil(@contact.deleted_at)}
            class="contacts-workspace__settings"
            id="contact-sync-settings"
          >
            <summary>
              <.dm_mdi name="cloud-sync-outline" class="contacts-workspace__icon" />
              Synchronization & account
              <.dm_mdi name="chevron-down" class="contacts-workspace__icon" />
            </summary>
            <div class="contacts-workspace__settings-content">
              <.form
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
                <p class="contacts-workspace__hint">
                  Keep changes in sync with this contact’s iCloud account.
                </p>
                <.dm_btn type="submit" variant="outline">Save sync preference</.dm_btn>
              </.form>
              <.form for={%{"account_id" => ""}} as={:copy} id="contact-copy-form" phx-submit="copy">
                <.dm_select
                  name="copy[account_id]"
                  id="contact-copy-account"
                  label="Copy to Account"
                  options={account_options(@accounts)}
                  value=""
                />
                <.dm_btn id="copy-contact" type="submit" variant="outline">Make local copy</.dm_btn>
              </.form>
            </div>
          </details>
          <div
            :if={editable?(@contact) && is_nil(@contact.deleted_at)}
            class="contacts-workspace__danger-zone"
          >
            <.dm_btn
              id="delete-contact"
              variant="ghost"
              confirm={
                if @contact.sync_to_icloud && @contact.resource_id,
                  do: "Delete this contact locally and queue its iCloud deletion?",
                  else: "Delete this local contact?"
              }
              confirm_title="Delete contact"
              phx-click="delete"
            >
              <.dm_mdi name="trash-can-outline" class="contacts-workspace__icon" /> Delete contact
            </.dm_btn>
          </div>
        </div>
      </section>
    </section>
    """
  end

  defp reload_contacts(socket) do
    contacts =
      Contacts.list_contacts(
        search: socket.assigns.search,
        account_id: socket.assigns.account_id,
        limit: 51,
        offset: socket.assigns.offset,
        include_deleted_conflicts: true
      )

    visible = Enum.take(contacts, 50)

    assign(socket,
      contacts: visible,
      contact_groups:
        Enum.chunk_by(visible, &contact_initial/1) |> Enum.map(&{contact_initial(hd(&1)), &1}),
      has_next: length(contacts) > 50
    )
  end

  defp contact_path(contact, action, account_id) do
    path =
      case action do
        :index -> ~p"/contacts"
        :new -> ~p"/contacts/new"
        :show -> ~p"/contacts/#{contact.id}"
        :edit -> ~p"/contacts/#{contact.id}/edit"
      end

    if account_id, do: path <> "?" <> URI.encode_query(%{"account" => account_id}), else: path
  end

  defp contact_initial(contact) do
    initial = contact.full_name |> String.trim() |> String.first() |> String.upcase()
    if Regex.match?(~r/^\p{L}/u, initial), do: initial, else: "#"
  end

  defp contact_subtitle(contact) do
    cond do
      contact.organization && contact.organization != "" -> contact.organization
      contact.emails != [] -> hd(contact.emails)["value"]
      contact.phones != [] -> hd(contact.phones)["value"]
      true -> if contact.collection_id, do: "iCloud contact", else: "Local contact"
    end
  end

  defp account_heading(nil, _accounts), do: "All contacts"

  defp account_heading(account_id, accounts),
    do: Enum.find(accounts, &(&1.id == account_id)).name || "Account contacts"

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

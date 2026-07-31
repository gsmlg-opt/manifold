defmodule ManifoldWeb.MailboxLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.Accounts

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Mailboxes",
       domains: Accounts.list_domains(),
       mailboxes: Accounts.list_mailboxes(),
       setup_step: :closed,
       domain_mode: nil,
       selected_domain: nil,
       domain_form: empty_form(:domain),
       mailbox_form: empty_form(:mailbox),
       return_provider: nil
     )}
  end

  @impl Phoenix.LiveView
  def handle_event(
        "open-mailbox-setup",
        _params,
        %{assigns: %{setup_step: :closed}} = socket
      ) do
    mode = if socket.assigns.domains == [], do: :new, else: :existing

    {:noreply,
     assign(socket,
       setup_step: :domain,
       domain_mode: mode,
       selected_domain: nil,
       domain_form: empty_form(:domain),
       mailbox_form: empty_form(:mailbox)
     )}
  end

  def handle_event("open-mailbox-setup", _params, socket), do: {:noreply, socket}

  def handle_event(
        "change-mailbox-domain",
        %{"domain" => %{"selection" => "new"} = attrs},
        %{assigns: %{setup_step: :domain}} = socket
      ) do
    domain_form = attrs |> Map.take(["name"]) |> to_form(as: :domain)
    {:noreply, assign(socket, domain_mode: :new, domain_form: domain_form)}
  end

  def handle_event(
        "change-mailbox-domain",
        %{"domain" => %{"selection" => domain_id}},
        %{assigns: %{setup_step: :domain}} = socket
      ) do
    mode = if Enum.any?(socket.assigns.domains, &(&1.id == domain_id)), do: :existing, else: nil
    {:noreply, assign(socket, :domain_mode, mode)}
  end

  def handle_event("change-mailbox-domain", _params, socket), do: {:noreply, socket}

  def handle_event(
        "continue-mailbox-domain",
        %{"domain" => %{} = attrs},
        %{assigns: %{setup_step: :domain, domain_mode: :new}} = socket
      ) do
    case Accounts.create_domain(Map.take(attrs, ["name"])) do
      {:ok, domain} ->
        {:noreply,
         assign(socket,
           domains: Accounts.list_domains(),
           setup_step: :mailbox,
           selected_domain: domain,
           mailbox_form: empty_form(:mailbox)
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :domain_form, error_form(changeset, :domain))}
    end
  end

  def handle_event(
        "continue-mailbox-domain",
        %{"domain" => %{"selection" => domain_id}},
        %{assigns: %{setup_step: :domain, domain_mode: :existing}} = socket
      ) do
    case Enum.find(socket.assigns.domains, &(&1.id == domain_id)) do
      nil ->
        {:noreply, socket}

      domain ->
        {:noreply,
         assign(socket,
           setup_step: :mailbox,
           domain_mode: :existing,
           selected_domain: domain,
           mailbox_form: empty_form(:mailbox)
         )}
    end
  end

  def handle_event("continue-mailbox-domain", _params, socket), do: {:noreply, socket}

  def handle_event(
        "create-mailbox",
        %{"mailbox" => %{} = attrs},
        %{assigns: %{setup_step: :mailbox, selected_domain: domain}} = socket
      )
      when not is_nil(domain) do
    mailbox_attrs = %{
      local_part: attrs["local_part"],
      display_name: attrs["display_name"]
    }

    case Accounts.create_mailbox(domain, mailbox_attrs) do
      {:ok, mailbox} ->
        {:noreply, finish_mailbox_creation(socket, mailbox)}

      {:error, changeset} ->
        {:noreply, assign(socket, :mailbox_form, error_form(changeset, :mailbox))}
    end
  end

  def handle_event("create-mailbox", _params, socket), do: {:noreply, socket}

  def handle_event(
        "back-mailbox-setup",
        _params,
        %{assigns: %{setup_step: :mailbox}} = socket
      ) do
    {:noreply,
     assign(socket,
       setup_step: :domain,
       selected_domain: nil,
       mailbox_form: empty_form(:mailbox)
     )}
  end

  def handle_event("back-mailbox-setup", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-mailbox-setup", _params, socket),
    do: {:noreply, reset_mailbox_setup(socket)}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>Mailboxes</h1>
          <p class="settings-intro">Create local delivery addresses for Manifold.</p>
        </div>
        <div class="settings-heading-actions">
          <button
            id="create-mailbox-button"
            type="button"
            class="settings-action settings-action-primary"
            phx-click="open-mailbox-setup"
          >
            <.dm_mdi name="plus" /> Create mailbox
          </button>
          <nav class="settings-nav" aria-label="Settings">
            <.link navigate={~p"/settings/accounts"}>External accounts</.link>
            <.link navigate={~p"/domains"}>Domains</.link>
            <.link navigate={~p"/aliases"}>Aliases</.link>
          </nav>
        </div>
      </div>

      <section
        :if={@setup_step != :closed}
        id="mailbox-setup-panel"
        class="mailbox-setup-panel"
        aria-labelledby="mailbox-setup-title"
      >
        <span class="add-account-step">
          {if @setup_step == :domain, do: "Step 1 of 2", else: "Step 2 of 2"}
        </span>
        <h2 id="mailbox-setup-title">Create a local mailbox</h2>

        <form
          :if={@setup_step == :domain}
          id="mailbox-domain-form"
          phx-submit="continue-mailbox-domain"
          phx-change="change-mailbox-domain"
          class="mailbox-setup-form"
        >
          <h3 id="mailbox-domain-heading" tabindex="-1" phx-mounted={JS.focus()}>
            Choose or create a domain
          </h3>
          <label :if={@domains != []} for="mailbox-domain-selection">Domain</label>
          <select
            :if={@domains != []}
            id="mailbox-domain-selection"
            name="domain[selection]"
            required
          >
            <option value="">Select a domain</option>
            <option :for={domain <- @domains} value={domain.id}>
              {domain.normalized_domain}
            </option>
            <option value="new" selected={@domain_mode == :new}>Create a new domain</option>
          </select>
          <input
            :if={@domains == []}
            type="hidden"
            name="domain[selection]"
            value="new"
          />
          <div :if={@domain_mode == :new} class="mailbox-domain-name">
            <label for="new-domain-name">Domain name</label>
            <input
              id="new-domain-name"
              name={@domain_form[:name].name}
              value={@domain_form[:name].value}
              placeholder="example.com"
              autocomplete="off"
              aria-invalid={if @domain_form[:name].errors == [], do: nil, else: "true"}
              aria-describedby={
                if @domain_form[:name].errors == [], do: nil, else: "domain-name-error"
              }
              required
            />
            <p
              :for={error <- @domain_form[:name].errors}
              id="domain-name-error"
              class="settings-error"
            >
              {error_message(error)}
            </p>
          </div>
          <button type="submit" class="settings-action settings-action-primary">Continue</button>
        </form>

        <form
          :if={@setup_step == :mailbox}
          id="create-mailbox-form"
          phx-submit="create-mailbox"
          class="mailbox-setup-form"
        >
          <h3 id="mailbox-details-heading" tabindex="-1" phx-mounted={JS.focus()}>
            Create the mailbox
          </h3>
          <label for="mailbox-local-part">Local part</label>
          <div class="mailbox-address-fields">
            <input
              id="mailbox-local-part"
              name={@mailbox_form[:local_part].name}
              value={@mailbox_form[:local_part].value}
              autocomplete="off"
              aria-invalid={if @mailbox_form[:local_part].errors == [], do: nil, else: "true"}
              aria-describedby={
                if @mailbox_form[:local_part].errors == [],
                  do: nil,
                  else: "mailbox-local-part-error"
              }
              required
            />
            <span id="mailbox-address-domain">@{@selected_domain.normalized_domain}</span>
          </div>
          <p
            :for={error <- @mailbox_form[:local_part].errors}
            id="mailbox-local-part-error"
            class="settings-error"
          >
            {error_message(error)}
          </p>
          <label for="mailbox-display-name">Display name <span>(optional)</span></label>
          <input
            id="mailbox-display-name"
            name={@mailbox_form[:display_name].name}
            value={@mailbox_form[:display_name].value}
            autocomplete="name"
          />
          <button type="submit" class="settings-action settings-action-primary">
            Create mailbox
          </button>
        </form>

        <footer class="mailbox-setup-footer">
          <button
            :if={@setup_step == :mailbox}
            id="back-mailbox-setup"
            type="button"
            class="settings-action"
            phx-click="back-mailbox-setup"
          >
            Back
          </button>
          <button
            id="cancel-mailbox-setup"
            type="button"
            class="settings-action"
            phx-click={JS.push("cancel-mailbox-setup") |> JS.focus(to: "#create-mailbox-button")}
          >
            Cancel
          </button>
        </footer>
      </section>

      <div class="table-scroll">
        <table id="mailboxes">
          <thead>
            <tr>
              <th>Mailbox</th><th>Name</th><th>Active</th><th>Plus Addressing</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={mailbox <- @mailboxes}>
              <td>{mailbox.local_part}@{mailbox.domain.normalized_domain}</td>
              <td>{mailbox.display_name}</td>
              <td>{yes_no(mailbox.active)}</td>
              <td>{yes_no(mailbox.plus_addressing_enabled)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </section>
    """
  end

  defp empty_form(name), do: to_form(%{}, as: name)

  defp error_form(changeset, name) do
    changeset
    |> Map.put(:action, :insert)
    |> to_form(as: name)
  end

  defp finish_mailbox_creation(socket, _mailbox) do
    socket
    |> assign(:domains, Accounts.list_domains())
    |> assign(:mailboxes, Accounts.list_mailboxes())
    |> reset_mailbox_setup()
    |> put_flash(:info, "Mailbox created.")
  end

  defp reset_mailbox_setup(socket) do
    assign(socket,
      setup_step: :closed,
      domain_mode: nil,
      selected_domain: nil,
      domain_form: empty_form(:domain),
      mailbox_form: empty_form(:mailbox)
    )
  end

  defp error_message({message, options}) do
    Enum.reduce(options, message, fn {key, value}, rendered ->
      String.replace(rendered, "%{#{key}}", to_string(value))
    end)
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
end

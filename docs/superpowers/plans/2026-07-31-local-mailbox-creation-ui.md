# Local Mailbox Creation UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a test-covered web flow that creates a local mailbox, creates its domain when needed, and resumes external-account setup with the new mailbox selected.

**Architecture:** Extend the existing mailbox LiveView with transient two-step form state and keep all persistence behind `Manifold.Accounts`. Reuse the existing domain and mailbox changesets, retarget their uniqueness errors to visible form fields, and use allowlisted query parameters for the handoff between the mailbox and external-account LiveViews.

**Tech Stack:** Elixir 1.18, Phoenix 1.8, Phoenix LiveView 1.2, Ecto 3.14, ExUnit, Duskmoon Bundler, CSS.

---

## File Map

- Modify `apps/manifold_accounts/lib/manifold/accounts/schema/domain.ex` so duplicate-domain errors attach to the visible `name` field.
- Modify `apps/manifold_accounts/lib/manifold/accounts/schema/mailbox.ex` so duplicate-mailbox errors attach to the visible `local_part` field.
- Modify `apps/manifold_accounts/test/manifold/accounts_test.exs` to lock down those error keys.
- Modify `apps/manifold_web/lib/manifold_web/live/mailbox_live/index.ex` to own the two-step create flow, validation state, and allowlisted return marker.
- Create `apps/manifold_web/test/manifold_web/mailbox_live_test.exs` for mailbox creation, domain creation, validation, state guards, and return navigation.
- Modify `apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex` to generate and restore the trusted mailbox-creation handoff.
- Modify `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs` to cover handoff links, restoration, and fail-closed query parameters.
- Modify `apps/manifold_web/assets/css/app.css` for the responsive setup panel, native form controls, field errors, and address preview.

### Task 1: Attach uniqueness errors to visible form fields

**Files:**
- Modify: `apps/manifold_accounts/test/manifold/accounts_test.exs:8`
- Modify: `apps/manifold_accounts/lib/manifold/accounts/schema/domain.ex:21-27`
- Modify: `apps/manifold_accounts/lib/manifold/accounts/schema/mailbox.ex:19-27`

- [ ] **Step 1: Write the failing schema-boundary tests**

Add these tests near the top of `apps/manifold_accounts/test/manifold/accounts_test.exs`:

```elixir
test "duplicate domains report the error on name" do
  assert {:ok, _domain} = Accounts.create_domain(%{name: "Duplicate.test"})
  assert {:error, changeset} = Accounts.create_domain(%{name: "duplicate.TEST"})

  assert {"has already been taken", _metadata} = changeset.errors[:name]
  refute Keyword.has_key?(changeset.errors, :normalized_domain)
end

test "duplicate mailboxes report the error on local part" do
  domain = domain_fixture()
  assert {:ok, _mailbox} = Accounts.create_mailbox(domain, %{local_part: "Person"})
  assert {:error, changeset} = Accounts.create_mailbox(domain, %{local_part: "person"})

  assert {"has already been taken", _metadata} = changeset.errors[:local_part]
  refute Keyword.has_key?(changeset.errors, :domain_id)
end
```

- [ ] **Step 2: Run the tests and confirm the current error keys fail**

Run:

```bash
devenv shell -- mix test apps/manifold_accounts/test/manifold/accounts_test.exs
```

Expected: both new tests fail because the uniqueness errors currently attach to `normalized_domain` and `domain_id`.

- [ ] **Step 3: Retarget the uniqueness constraints**

In `domain.ex`, replace the final changeset stage with:

```elixir
|> unique_constraint(:normalized_domain, error_key: :name)
```

In `mailbox.ex`, replace the final changeset stage with:

```elixir
|> unique_constraint([:domain_id, :canonical_local_part], error_key: :local_part)
```

- [ ] **Step 4: Run the scoped Accounts tests**

Run:

```bash
devenv shell -- mix test apps/manifold_accounts/test/manifold/accounts_test.exs
```

Expected: all Accounts tests pass with 0 failures.

- [ ] **Step 5: Commit the error-key contract**

```bash
git add apps/manifold_accounts/lib/manifold/accounts/schema/domain.ex \
  apps/manifold_accounts/lib/manifold/accounts/schema/mailbox.ex \
  apps/manifold_accounts/test/manifold/accounts_test.exs
git commit -m "fix(accounts): expose duplicate routing errors on form fields"
```

### Task 2: Create mailboxes under an existing domain

**Files:**
- Create: `apps/manifold_web/test/manifold_web/mailbox_live_test.exs`
- Modify: `apps/manifold_web/lib/manifold_web/live/mailbox_live/index.ex:1-35`

- [ ] **Step 1: Write failing tests for the existing-domain path**

Create `apps/manifold_web/test/manifold_web/mailbox_live_test.exs`:

```elixir
defmodule ManifoldWeb.MailboxLiveTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Accounts

  test "creates a mailbox under an existing domain", %{conn: conn} do
    {:ok, domain} = Accounts.create_domain(%{name: unique_domain("existing")})

    assert {:ok, view, _html} = live(conn, ~p"/mailboxes")
    assert has_element?(view, "#create-mailbox-button", "Create mailbox")
    refute has_element?(view, "#mailbox-setup-panel")

    view |> element("#create-mailbox-button") |> render_click()

    assert has_element?(view, "#mailbox-domain-heading", "Choose or create a domain")
    assert has_element?(view, "#mailbox-domain-selection option[value='#{domain.id}']")

    view
    |> form("#mailbox-domain-form", %{domain: %{selection: domain.id}})
    |> render_submit()

    assert has_element?(view, "#mailbox-details-heading", "Create the mailbox")
    assert has_element?(view, "#mailbox-address-domain", "@#{domain.normalized_domain}")

    html =
      view
      |> form("#create-mailbox-form", %{
        mailbox: %{local_part: "person", display_name: "Personal mail"}
      })
      |> render_submit()

    assert html =~ "person@#{domain.normalized_domain}"
    assert html =~ "Mailbox created."
    refute has_element?(view, "#mailbox-setup-panel")

    assert [mailbox] = Accounts.list_mailboxes(domain)
    assert mailbox.local_part == "person"
    assert mailbox.display_name == "Personal mail"
    assert mailbox.active
    assert mailbox.plus_addressing_enabled
  end

  test "mailbox validation stays on the details step", %{conn: conn} do
    {:ok, domain} = Accounts.create_domain(%{name: unique_domain("validation")})
    {:ok, _mailbox} = Accounts.create_mailbox(domain, %{local_part: "taken"})
    {:ok, view, _html} = live(conn, ~p"/mailboxes")

    open_existing_domain(view, domain)

    html =
      view
      |> form("#create-mailbox-form", %{mailbox: %{local_part: "bad local part"}})
      |> render_submit()

    assert html =~ "has invalid format"
    assert has_element?(view, "#mailbox-local-part-error.settings-error")

    html =
      view
      |> form("#create-mailbox-form", %{mailbox: %{local_part: "TAKEN"}})
      |> render_submit()

    assert html =~ "has already been taken"
    assert Accounts.list_mailboxes(domain) |> length() == 1
  end

  test "cancel closes and clears transient mailbox setup", %{conn: conn} do
    {:ok, domain} = Accounts.create_domain(%{name: unique_domain("cancel")})
    {:ok, view, _html} = live(conn, ~p"/mailboxes")

    open_existing_domain(view, domain)
    assert has_element?(view, "#mailbox-setup-panel")

    view |> element("#cancel-mailbox-setup") |> render_click()

    refute has_element?(view, "#mailbox-setup-panel")
    assert has_element?(
             view,
             "#cancel-mailbox-setup[phx-click*='focus'][phx-click*='#create-mailbox-button']",
             "Cancel"
           ) == false

    view |> element("#create-mailbox-button") |> render_click()
    assert has_element?(view, "#mailbox-domain-heading")
    refute has_element?(view, "#mailbox-details-heading")
  end

  defp open_existing_domain(view, domain) do
    view |> element("#create-mailbox-button") |> render_click()

    view
    |> form("#mailbox-domain-form", %{domain: %{selection: domain.id}})
    |> render_submit()
  end

  defp unique_domain(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}.test"
  end
end
```

- [ ] **Step 2: Run the new test file and verify it fails**

Run:

```bash
devenv shell -- mix test apps/manifold_web/test/manifold_web/mailbox_live_test.exs
```

Expected: fail because `#create-mailbox-button`, form events, and setup state do not exist.

- [ ] **Step 3: Add transient setup state and guarded events**

Replace the current `mount/3` assignment in `mailbox_live/index.ex` with:

```elixir
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
```

Add the existing-domain event handlers before `render/1`:

```elixir
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
      "continue-mailbox-domain",
      %{"domain" => %{"selection" => domain_id}},
      %{assigns: %{setup_step: :domain}} = socket
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
      %{"mailbox" => attrs},
      %{assigns: %{setup_step: :mailbox, selected_domain: domain}} = socket
    )
    when not is_nil(domain) do
  case Accounts.create_mailbox(domain, attrs) do
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
```

Add these private helpers:

```elixir
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
```

- [ ] **Step 4: Replace the list-only template with the existing-domain setup UI**

Keep the current table columns and rows, but give the table `id="mailboxes"` and wrap it in `<div class="table-scroll">`. Add this header and panel before the table:

```heex
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
    class="mailbox-setup-form"
  >
    <h3 id="mailbox-domain-heading" tabindex="-1" phx-mounted={JS.focus()}>
      Choose or create a domain
    </h3>
    <label for="mailbox-domain-selection">Domain</label>
    <select id="mailbox-domain-selection" name="domain[selection]" required>
      <option value="">Select a domain</option>
      <option :for={domain <- @domains} value={domain.id}>
        {domain.normalized_domain}
      </option>
      <option value="new">Create a new domain</option>
    </select>
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
```

- [ ] **Step 5: Run the mailbox LiveView tests**

Run:

```bash
devenv shell -- mix test apps/manifold_web/test/manifold_web/mailbox_live_test.exs
```

Expected: the existing-domain creation, validation, and reset tests pass with 0 failures.

- [ ] **Step 6: Commit the existing-domain flow**

```bash
git add apps/manifold_web/lib/manifold_web/live/mailbox_live/index.ex \
  apps/manifold_web/test/manifold_web/mailbox_live_test.exs
git commit -m "feat(web): create local mailboxes from settings"
```

### Task 3: Create a domain inside mailbox setup and enforce step guards

**Files:**
- Modify: `apps/manifold_web/test/manifold_web/mailbox_live_test.exs`
- Modify: `apps/manifold_web/lib/manifold_web/live/mailbox_live/index.ex`

- [ ] **Step 1: Add failing tests for new-domain creation and forged events**

Add:

```elixir
test "creates a domain before creating the first mailbox", %{conn: conn} do
  assert Accounts.list_domains() == []
  {:ok, view, _html} = live(conn, ~p"/mailboxes")

  view |> element("#create-mailbox-button") |> render_click()

  assert has_element?(view, "#new-domain-name")
  refute has_element?(view, "#mailbox-domain-selection")

  html =
    view
    |> form("#mailbox-domain-form", %{domain: %{name: "bad domain"}})
    |> render_submit()

  assert html =~ "domain syntax is invalid"
  assert has_element?(view, "#domain-name-error.settings-error")

  view
  |> form("#mailbox-domain-form", %{domain: %{name: "New-Mail.TEST"}})
  |> render_submit()

  assert has_element?(view, "#mailbox-address-domain", "@new-mail.test")

  view
  |> form("#create-mailbox-form", %{mailbox: %{local_part: "inbox"}})
  |> render_submit()

  assert [%{normalized_domain: "new-mail.test"}] = Accounts.list_domains()
  assert [%{canonical_local_part: "inbox"}] = Accounts.list_mailboxes()
end

test "can switch from an existing domain to new-domain creation", %{conn: conn} do
  {:ok, existing} = Accounts.create_domain(%{name: unique_domain("switch")})
  {:ok, view, _html} = live(conn, ~p"/mailboxes")
  view |> element("#create-mailbox-button") |> render_click()

  view
  |> form("#mailbox-domain-form", %{domain: %{selection: "new"}})
  |> render_change()

  assert has_element?(view, "#new-domain-name")

  view
  |> form("#mailbox-domain-form", %{domain: %{name: existing.normalized_domain}})
  |> render_submit()

  assert render(view) =~ "has already been taken"
  assert has_element?(view, "#domain-name-error")
end

test "forged setup events cannot bypass domain selection", %{conn: conn} do
  {:ok, domain} = Accounts.create_domain(%{name: unique_domain("guard")})
  {:ok, view, _html} = live(conn, ~p"/mailboxes")

  render_hook(view, "continue-mailbox-domain", %{"domain" => %{"selection" => domain.id}})
  render_hook(view, "create-mailbox", %{"mailbox" => %{"local_part" => "forged"}})

  refute has_element?(view, "#mailbox-setup-panel")
  assert Accounts.list_mailboxes(domain) == []

  view |> element("#create-mailbox-button") |> render_click()
  render_hook(view, "continue-mailbox-domain", %{"domain" => %{"selection" => "unknown"}})

  assert has_element?(view, "#mailbox-domain-heading")
  refute has_element?(view, "#mailbox-details-heading")
end
```

- [ ] **Step 2: Run the new tests and verify they fail**

Run:

```bash
devenv shell -- mix test apps/manifold_web/test/manifold_web/mailbox_live_test.exs
```

Expected: the new tests fail because `"new"` selection, domain persistence, and the conditional field do not exist.

- [ ] **Step 3: Add new-domain mode and persistence**

Add these guarded handlers before the existing-domain submit handler:

```elixir
def handle_event(
      "change-mailbox-domain",
      %{"domain" => %{"selection" => "new"}},
      %{assigns: %{setup_step: :domain}} = socket
    ) do
  {:noreply, assign(socket, domain_mode: :new, domain_form: empty_form(:domain))}
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
      %{"domain" => attrs},
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
```

Update the existing-domain submit handler so it only matches
`%{assigns: %{setup_step: :domain, domain_mode: :existing}}`.

- [ ] **Step 4: Make the domain form switch modes**

Add `phx-change="change-mailbox-domain"` to `#mailbox-domain-form`. Render the select only when domains exist, and render the new-domain field only in new mode:

```heex
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
```

- [ ] **Step 5: Run the mailbox tests**

Run:

```bash
devenv shell -- mix test apps/manifold_web/test/manifold_web/mailbox_live_test.exs
```

Expected: all mailbox LiveView tests pass with 0 failures.

- [ ] **Step 6: Commit the new-domain path**

```bash
git add apps/manifold_web/lib/manifold_web/live/mailbox_live/index.ex \
  apps/manifold_web/test/manifold_web/mailbox_live_test.exs
git commit -m "feat(web): create domains during mailbox setup"
```

### Task 4: Resume external-account setup after mailbox creation

**Files:**
- Modify: `apps/manifold_web/test/manifold_web/mailbox_live_test.exs`
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs:427-444`
- Modify: `apps/manifold_web/lib/manifold_web/live/mailbox_live/index.ex`
- Modify: `apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex:7-19,242-247`

- [ ] **Step 1: Write failing handoff tests**

Add this mailbox test:

```elixir
test "external-account entry returns with the created mailbox", %{conn: conn} do
  {:ok, domain} = Accounts.create_domain(%{name: unique_domain("return")})

  assert {:ok, view, _html} =
           live(conn, ~p"/mailboxes?#{[source: "external_account", provider: "gmail"]}")

  open_existing_domain(view, domain)

  view
  |> form("#create-mailbox-form", %{mailbox: %{local_part: "imports"}})
  |> render_submit()

  [mailbox] = Accounts.list_mailboxes(domain)

  assert_redirect(
    view,
    ~p"/settings/accounts?#{[provider: "gmail", mailbox_id: mailbox.id]}"
  )
end
```

Replace the existing inactive-mailbox empty-state assertion in
`external_accounts_web_test.exs` and add restoration tests:

```elixir
assert has_element?(
         view,
         "#create-local-mailbox-link[href*='provider=gmail'][href*='source=external_account']",
         "Create local mailbox"
       )
```

```elixir
test "validated handoff restores provider and mailbox selection", %{
  conn: conn,
  mailbox: mailbox
} do
  assert {:ok, view, _html} =
           live(conn, ~p"/settings/accounts?#{[provider: "gmail", mailbox_id: mailbox.id]}")

  assert has_element?(view, "#add-account-mailbox-heading", "Choose a local mailbox")
  assert has_element?(
           view,
           "#add-account-mailbox-id option[value='#{mailbox.id}'][selected]"
         )

  assert has_element?(
           view,
           "#continue-add-account[href='/connectors/gmail/start?mailbox_id=#{mailbox.id}']",
           "Continue to Gmail"
         )
end

test "invalid handoff parameters fail closed", %{conn: conn, mailbox: mailbox} do
  assert {:ok, forged_provider, _html} =
           live(conn, ~p"/settings/accounts?#{[provider: "imap", mailbox_id: mailbox.id]}")

  refute has_element?(forged_provider, "#add-account-panel")

  assert {:ok, unknown_mailbox, _html} =
           live(
             conn,
             ~p"/settings/accounts?#{[provider: "gmail", mailbox_id: Ecto.UUID.generate()]}"
           )

  refute has_element?(unknown_mailbox, "#add-account-panel")

  mailbox
  |> Ecto.Changeset.change(active: false)
  |> Manifold.Repo.update!()

  assert {:ok, inactive_mailbox, _html} =
           live(conn, ~p"/settings/accounts?#{[provider: "gmail", mailbox_id: mailbox.id]}")

  refute has_element?(inactive_mailbox, "#add-account-panel")
  refute has_element?(inactive_mailbox, "#continue-add-account")
end
```

- [ ] **Step 2: Run the two scoped web test files and verify failure**

Run:

```bash
devenv shell -- mix test \
  apps/manifold_web/test/manifold_web/mailbox_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: fail because the mailbox LiveView ignores source parameters and the external-account LiveView does not restore query state.

- [ ] **Step 3: Allowlist the mailbox return marker**

Change `MailboxLive.Index.mount/3` to receive `params`, and assign:

```elixir
return_provider: return_provider(params)
```

Add:

```elixir
defp return_provider(%{"source" => "external_account", "provider" => provider})
     when provider in ["gmail", "microsoft"],
     do: provider

defp return_provider(_params), do: nil
```

Split `finish_mailbox_creation/2`:

```elixir
defp finish_mailbox_creation(%{assigns: %{return_provider: provider}} = socket, mailbox)
     when provider in ["gmail", "microsoft"] do
  push_navigate(socket,
    to: ~p"/settings/accounts?#{[provider: provider, mailbox_id: mailbox.id]}"
  )
end

defp finish_mailbox_creation(socket, _mailbox) do
  socket
  |> assign(:domains, Accounts.list_domains())
  |> assign(:mailboxes, Accounts.list_mailboxes())
  |> reset_mailbox_setup()
  |> put_flash(:info, "Mailbox created.")
end
```

- [ ] **Step 4: Restore only a configured provider and active mailbox**

Add `handle_params/3` to `ExternalAccountLive.Index`:

```elixir
@impl Phoenix.LiveView
def handle_params(params, _uri, socket) do
  {:noreply, restore_mailbox_handoff(socket, params)}
end
```

Add:

```elixir
defp restore_mailbox_handoff(
       socket,
       %{"provider" => provider, "mailbox_id" => mailbox_id}
     )
     when provider in ["gmail", "microsoft"] do
  valid_provider =
    provider_configured?(socket.assigns.configured_providers, provider)

  valid_mailbox =
    Enum.any?(socket.assigns.mailboxes, &(&1.id == mailbox_id))

  if valid_provider and valid_mailbox do
    assign(socket,
      add_account_step: :mailbox,
      selected_provider: provider,
      selected_mailbox_id: mailbox_id
    )
  else
    reset_add_account(socket)
  end
end

defp restore_mailbox_handoff(socket, _params), do: reset_add_account(socket)
```

Replace the empty-state link with:

```heex
<.link
  id="create-local-mailbox-link"
  navigate={
    ~p"/mailboxes?#{[source: "external_account", provider: @selected_provider]}"
  }
>
  Create local mailbox
</.link>
```

- [ ] **Step 5: Run the scoped handoff tests**

Run:

```bash
devenv shell -- mix test \
  apps/manifold_web/test/manifold_web/mailbox_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: all tests in both files pass with 0 failures.

- [ ] **Step 6: Commit the trusted handoff**

```bash
git add apps/manifold_web/lib/manifold_web/live/mailbox_live/index.ex \
  apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex \
  apps/manifold_web/test/manifold_web/mailbox_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
git commit -m "feat(web): resume account setup after mailbox creation"
```

### Task 5: Add accessible responsive styling and complete verification

**Files:**
- Modify: `apps/manifold_web/test/manifold_web/mailbox_live_test.exs`
- Modify: `apps/manifold_web/assets/css/app.css:290-535,1349-1443`

- [ ] **Step 1: Add failing accessibility assertions**

Add:

```elixir
test "setup panel labels steps and manages focus", %{conn: conn} do
  {:ok, domain} = Accounts.create_domain(%{name: unique_domain("a11y")})
  {:ok, view, _html} = live(conn, ~p"/mailboxes")

  view |> element("#create-mailbox-button") |> render_click()

  assert has_element?(
           view,
           "#mailbox-setup-panel[aria-labelledby='mailbox-setup-title'] #mailbox-domain-heading[tabindex='-1'][phx-mounted*='focus']"
         )

  assert has_element?(
           view,
           "#cancel-mailbox-setup[phx-click*='cancel-mailbox-setup'][phx-click*='focus'][phx-click*='#create-mailbox-button']"
         )

  view
  |> form("#mailbox-domain-form", %{domain: %{selection: domain.id}})
  |> render_submit()

  assert has_element?(
           view,
           "#mailbox-details-heading[tabindex='-1'][phx-mounted*='focus']"
         )
end
```

- [ ] **Step 2: Run the mailbox test and confirm the semantic selectors**

Run:

```bash
devenv shell -- mix test apps/manifold_web/test/manifold_web/mailbox_live_test.exs
```

Expected: fail if any required panel label or focus hook is missing; otherwise pass and proceed directly to styling.

- [ ] **Step 3: Add the setup-panel CSS**

Add next to the existing settings and add-account rules:

```css
.mailbox-setup-panel {
  max-width: 760px;
  margin: 28px 0;
  padding: 22px;
  border: 1px solid #b8dfd1;
  border-left: 4px solid #087f5b;
  border-radius: 8px;
  background: #fbfdfc;
  box-shadow: 0 4px 16px rgb(32 36 44 / 8%);
}

.mailbox-setup-panel h2 {
  margin: 2px 0 0;
}

.mailbox-setup-form {
  display: grid;
  max-width: 560px;
  gap: 7px;
  margin-top: 18px;
}

.mailbox-setup-form label {
  color: #46505c;
  font-size: 13px;
  font-weight: 700;
}

.mailbox-setup-form label span {
  color: #68717d;
  font-weight: 500;
}

.mailbox-setup-form input,
.mailbox-setup-form select {
  width: 100%;
  min-width: 0;
  min-height: 42px;
  padding: 0 10px;
  border: 1px solid #b8c0ca;
  border-radius: 5px;
  background: #ffffff;
  color: #20242c;
}

.mailbox-setup-form input:focus,
.mailbox-setup-form select:focus {
  border-color: #087f5b;
  outline: 2px solid #b8dfd1;
  outline-offset: 1px;
}

.mailbox-setup-form .settings-action {
  width: fit-content;
  margin-top: 9px;
}

.mailbox-address-fields {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: center;
  gap: 8px;
}

#mailbox-address-domain {
  max-width: 260px;
  color: #46505c;
  overflow-wrap: anywhere;
}

.mailbox-domain-name {
  display: grid;
  gap: 7px;
}

.mailbox-setup-footer {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 20px;
  padding-top: 16px;
  border-top: 1px solid #dfe9e5;
}
```

Inside `@media (max-width: 780px)`, add:

```css
.mailbox-setup-panel {
  margin: 20px 0;
  padding: 18px;
}

.mailbox-address-fields {
  grid-template-columns: 1fr;
}

#mailbox-address-domain {
  max-width: 100%;
}

.mailbox-setup-footer {
  flex-wrap: wrap;
}
```

- [ ] **Step 4: Format and run scoped tests**

Run:

```bash
devenv shell -- mix format
devenv shell -- mix test \
  apps/manifold_accounts/test/manifold/accounts_test.exs \
  apps/manifold_web/test/manifold_web/mailbox_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: formatting succeeds and all in-scope tests pass with 0 failures.

- [ ] **Step 5: Compile strictly and rebuild assets**

Run:

```bash
devenv shell -- env MIX_ENV=test mix compile --warnings-as-errors
devenv shell -- mix assets.build
```

Expected: compilation exits 0 with no project warnings; both CSS and JS manifests are generated successfully.

- [ ] **Step 6: Run the full web regression suite**

Run:

```bash
devenv shell -- mix test apps/manifold_web/test
```

Expected: all web tests pass with 0 failures. The pre-change baseline is 47 tests; the final count increases by the new mailbox and handoff tests.

- [ ] **Step 7: Verify the real UI remotely**

Use the existing devenv process or start Phoenix on an unused port while retaining the repository’s non-loopback bind. Open `/mailboxes` in Chrome and verify at desktop and 375-pixel widths:

1. Create mailbox opens Step 1 and focuses its heading.
2. Existing-domain and new-domain paths both reach Step 2.
3. Invalid domain and local-part errors are visible beside their fields.
4. The address controls and action footer do not overflow horizontally.
5. A mailbox created from Add Account returns with Gmail or Microsoft 365 and the new mailbox selected.

Expected: no console errors, no horizontal page overflow, and the final OAuth continuation contains the validated mailbox ID.

- [ ] **Step 8: Commit the UI polish**

```bash
git add apps/manifold_web/assets/css/app.css \
  apps/manifold_web/test/manifold_web/mailbox_live_test.exs
git commit -m "style(web): polish local mailbox setup"
```

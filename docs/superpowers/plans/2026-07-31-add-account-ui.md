# Add Account UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace per-mailbox connector links with an accessible Add account wizard that hands a selected Gmail or Microsoft 365 provider and active local mailbox to the existing OAuth start route.

**Architecture:** Keep all temporary wizard state in `ManifoldWeb.ExternalAccountLive.Index`; LiveView moves between steps and validates selections against already-loaded provider and mailbox lists. The final action remains a normal link to `ConnectorOAuthController`, so OAuth, PKCE, provider calls, and persistence boundaries do not change.

**Tech Stack:** Elixir 1.18, Phoenix LiveView, HEEx, Phoenix.LiveViewTest, Manifold Accounts and Connectors contexts, plain CSS.

---

## File Map

- Modify `apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex`
  for transient wizard state, events, rendering, and OAuth handoff.
- Modify `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`
  for the complete wizard behavior and regressions around existing account
  actions and secret non-disclosure.
- Modify `apps/manifold_web/assets/css/app.css` for the inline panel, choice
  controls, unavailable-provider treatment, and narrow-screen layout.

No router, controller, connector context, schema, migration, or JavaScript
changes are required.

### Task 1: Build the Complete Functional Wizard

**Files:**
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`
- Modify: `apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex`

- [ ] **Step 1: Replace the landing-page test with the Add account entry requirement**

Replace `"settings accounts is available without authentication"` with:

```elixir
test "settings accounts exposes add account without authentication", %{conn: conn} do
  assert {:ok, view, html} = live(conn, "/settings/accounts")

  assert html =~ "External accounts"
  assert has_element?(view, "#add-account-button", "Add account")
  refute has_element?(view, "#add-account-panel")
  refute html =~ "/connectors/gmail/start"
  refute html =~ "/connectors/microsoft/start"
  refute html =~ "Log in"
end
```

- [ ] **Step 2: Add the configured-provider and OAuth handoff test**

Add:

```elixir
test "external account selection advances to an OAuth start link", %{
  conn: conn,
  mailbox: mailbox
} do
  {:ok, view, _html} = live(conn, "/settings/accounts")

  assert view
         |> element("#add-account-button")
         |> render_click() =~ "External account"

  html =
    view
    |> element("#external-account-type")
    |> render_click()

  assert html =~ "Choose a provider"
  assert has_element?(view, "#provider-gmail:not([disabled])", "Gmail")
  assert has_element?(view, "#provider-microsoft:not([disabled])", "Microsoft 365")

  html =
    view
    |> element("#provider-gmail")
    |> render_click()

  assert html =~ "Choose a local mailbox"
  refute has_element?(view, "#continue-add-account")

  view
  |> form("#add-account-mailbox-form", %{"mailbox_id" => mailbox.id})
  |> render_change()

  assert has_element?(
           view,
           "#continue-add-account[href='/connectors/gmail/start?mailbox_id=#{mailbox.id}']",
           "Continue to Gmail"
         )
end
```

- [ ] **Step 3: Replace the unavailable-provider test**

Replace `"unconfigured providers are not offered as connection targets"` with:

```elixir
test "unconfigured providers stay visible with disabled explanations", %{conn: conn} do
  Application.put_env(:manifold_connectors, :providers, [])

  {:ok, view, _html} = live(conn, "/settings/accounts")
  open_provider_step(view)

  html = render(view)

  assert has_element?(view, "#provider-gmail[disabled]")
  assert has_element?(view, "#provider-microsoft[disabled]")
  assert html =~ "Provider not configured"
  refute html =~ "/connectors/gmail/start"
  refute html =~ "/connectors/microsoft/start"
end
```

- [ ] **Step 4: Replace the inactive-mailbox test with the empty destination state**

Replace `"inactive mailboxes are not offered as connector destinations"` with:

```elixir
test "inactive mailboxes are excluded and the empty state links to mailbox management", %{
  conn: conn,
  mailbox: mailbox
} do
  mailbox
  |> Ecto.Changeset.change(active: false)
  |> Manifold.Repo.update!()

  {:ok, view, _html} = live(conn, "/settings/accounts")
  open_provider_step(view)

  html =
    view
    |> element("#provider-gmail")
    |> render_click()

  refute html =~ mailbox.local_part
  assert html =~ "Create an active local mailbox before connecting an external account."
  assert has_element?(view, "#manage-mailboxes-link", "Manage mailboxes")
  refute has_element?(view, "#continue-add-account")
end
```

Add this helper above `connect_account/3`:

```elixir
defp open_provider_step(view) do
  view
  |> element("#add-account-button")
  |> render_click()

  view
  |> element("#external-account-type")
  |> render_click()
end
```

- [ ] **Step 5: Run the scoped test file and verify RED**

Run:

```bash
mix test apps/manifold_web/test/manifold_web/external_accounts_web_test.exs --trace
```

Expected: assertion failures identify the missing `#add-account-button`,
wizard panel, provider choices, and mailbox form. If the command cannot reach
PostgreSQL, start the project PostgreSQL process and rerun until it reaches
these feature assertion failures.

- [ ] **Step 6: Add wizard state and validated events**

Extend `mount/3` with the new assigns:

```elixir
assign(socket,
  page_title: "External accounts",
  mailboxes: Accounts.list_active_mailboxes(),
  accounts: Connectors.list_accounts(),
  configured_providers: Connectors.configured_providers(),
  add_account_step: :closed,
  selected_provider: nil,
  selected_mailbox_id: nil
)
```

Add these handlers before the existing sync and disconnect handlers:

```elixir
def handle_event("open-add-account", _params, socket) do
  {:noreply,
   assign(socket,
     add_account_step: :account_type,
     selected_provider: nil,
     selected_mailbox_id: nil
   )}
end

def handle_event("choose-account-type", %{"type" => "external"}, socket) do
  {:noreply, assign(socket, :add_account_step, :provider)}
end

def handle_event("choose-provider", %{"provider" => provider}, socket)
    when provider in ["gmail", "microsoft"] do
  if provider_configured?(socket.assigns.configured_providers, provider) do
    {:noreply,
     assign(socket,
       add_account_step: :mailbox,
       selected_provider: provider,
       selected_mailbox_id: nil
     )}
  else
    {:noreply, socket}
  end
end

def handle_event("select-add-account-mailbox", %{"mailbox_id" => mailbox_id}, socket) do
  selected_mailbox_id =
    if Enum.any?(socket.assigns.mailboxes, &(&1.id == mailbox_id)),
      do: mailbox_id,
      else: nil

  {:noreply, assign(socket, :selected_mailbox_id, selected_mailbox_id)}
end
```

- [ ] **Step 7: Replace the legacy connector table with the inline wizard**

Replace the current heading with:

```heex
<div class="settings-heading">
  <div>
    <h1>External accounts</h1>
    <p class="settings-intro">
      Import mail from provider accounts into local Manifold mailboxes.
    </p>
  </div>
  <div class="settings-heading-actions">
    <button
      id="add-account-button"
      type="button"
      class="settings-action settings-action-primary"
      phx-click="open-add-account"
    >
      <.dm_mdi name="plus" /> Add account
    </button>
    <nav class="settings-nav" aria-label="Settings">
      <.link navigate={~p"/mailboxes"}>Mailboxes</.link>
      <.link navigate={~p"/domains"}>Domains</.link>
      <.link navigate={~p"/aliases"}>Aliases</.link>
    </nav>
  </div>
</div>
```

Delete the complete `Local mailboxes` heading and
`<table id="connector-mailboxes">` block. Insert before `Connected accounts`:

```heex
<section
  :if={@add_account_step != :closed}
  id="add-account-panel"
  class="add-account-panel"
  aria-labelledby="add-account-title"
>
  <header class="add-account-panel-header">
    <div>
      <span class="add-account-step">{add_account_step_label(@add_account_step)}</span>
      <h2 id="add-account-title">Add an email account</h2>
    </div>
  </header>

  <div :if={@add_account_step == :account_type}>
    <h3>What kind of account are you adding?</h3>
    <button
      id="external-account-type"
      type="button"
      class="add-account-choice"
      phx-click="choose-account-type"
      phx-value-type="external"
    >
      <.dm_mdi name="cloud-outline" />
      <span>
        <strong>External account</strong>
        <small>Connect an existing provider-hosted mailbox.</small>
      </span>
    </button>
  </div>

  <div :if={@add_account_step == :provider}>
    <h3>Choose a provider</h3>
    <div class="add-account-choices">
      <button
        :for={provider <- ["gmail", "microsoft"]}
        id={"provider-#{provider}"}
        type="button"
        class="add-account-choice"
        disabled={!provider_configured?(@configured_providers, provider)}
        phx-click="choose-provider"
        phx-value-provider={provider}
      >
        <.dm_mdi name={provider_icon(provider)} />
        <span>
          <strong>{provider_name(provider)}</strong>
          <small :if={provider_configured?(@configured_providers, provider)}>
            Import mail using read-only access.
          </small>
          <small :if={!provider_configured?(@configured_providers, provider)}>
            Provider not configured
          </small>
        </span>
      </button>
    </div>
  </div>

  <div :if={@add_account_step == :mailbox}>
    <h3>Choose a local mailbox</h3>
    <p class="settings-secondary">
      Imported {provider_name(@selected_provider)} mail will be delivered here.
    </p>

    <form
      :if={@mailboxes != []}
      id="add-account-mailbox-form"
      phx-change="select-add-account-mailbox"
    >
      <label for="add-account-mailbox-id">Local mailbox</label>
      <select id="add-account-mailbox-id" name="mailbox_id">
        <option value="">Select a mailbox</option>
        <option
          :for={mailbox <- @mailboxes}
          value={mailbox.id}
          selected={mailbox.id == @selected_mailbox_id}
        >
          {mailbox_address(mailbox)}
        </option>
      </select>
    </form>

    <div :if={@mailboxes == []} id="add-account-no-mailboxes" class="settings-empty">
      <p>Create an active local mailbox before connecting an external account.</p>
      <.link id="manage-mailboxes-link" navigate={~p"/mailboxes"}>
        Manage mailboxes
      </.link>
    </div>

    <a
      :if={@selected_mailbox_id}
      id="continue-add-account"
      class="settings-action settings-action-primary"
      href={
        ~p"/connectors/#{@selected_provider}/start?#{[mailbox_id: @selected_mailbox_id]}"
      }
    >
      Continue to {provider_name(@selected_provider)}
    </a>
  </div>
</section>
```

Add helpers alongside the current `provider_name/1` clauses:

```elixir
defp add_account_step_label(:account_type), do: "Step 1 of 3"
defp add_account_step_label(:provider), do: "Step 2 of 3"
defp add_account_step_label(:mailbox), do: "Step 3 of 3"

defp provider_configured?(configured_providers, provider),
  do: provider in configured_providers

defp provider_icon("gmail"), do: "gmail"
defp provider_icon("microsoft"), do: "microsoft"
```

- [ ] **Step 8: Format and verify GREEN**

Run:

```bash
mix format \
  apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
mix test apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
```

Expected: every external-account web test passes, including existing OAuth
callback, sync, disconnect, and secret non-disclosure coverage.

- [ ] **Step 9: Commit the functional wizard**

```bash
git add \
  apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
git commit -m "feat(web): add external account wizard"
```

### Task 2: Add Back, Cancel, and Responsive Styling

**Files:**
- Modify: `apps/manifold_web/test/manifold_web/external_accounts_web_test.exs`
- Modify: `apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex`
- Modify: `apps/manifold_web/assets/css/app.css`

- [ ] **Step 1: Add the Back and Cancel regression test**

Add:

```elixir
test "back moves one step and cancel resets account setup", %{conn: conn} do
  {:ok, view, _html} = live(conn, "/settings/accounts")
  open_provider_step(view)

  view
  |> element("#provider-gmail")
  |> render_click()

  assert view
         |> element("#back-add-account")
         |> render_click() =~ "Choose a provider"

  assert view
         |> element("#cancel-add-account")
         |> render_click() =~ "Connected accounts"

  refute has_element?(view, "#add-account-panel")

  html =
    view
    |> element("#add-account-button")
    |> render_click()

  assert html =~ "What kind of account are you adding?"
  refute html =~ "Choose a provider"
  refute html =~ "Choose a local mailbox"
end
```

- [ ] **Step 2: Run the new test and verify RED**

Run:

```bash
mix test apps/manifold_web/test/manifold_web/external_accounts_web_test.exs --trace
```

Expected: the new test fails because `#back-add-account` and
`#cancel-add-account` are absent.

- [ ] **Step 3: Implement Back and Cancel state transitions**

Add before the existing sync handler:

```elixir
def handle_event(
      "back-add-account",
      _params,
      %{assigns: %{add_account_step: :provider}} = socket
    ) do
  {:noreply,
   assign(socket,
     add_account_step: :account_type,
     selected_provider: nil,
     selected_mailbox_id: nil
   )}
end

def handle_event(
      "back-add-account",
      _params,
      %{assigns: %{add_account_step: :mailbox}} = socket
    ) do
  {:noreply,
   assign(socket,
     add_account_step: :provider,
     selected_mailbox_id: nil
   )}
end

def handle_event("cancel-add-account", _params, socket) do
  {:noreply, reset_add_account(socket)}
end
```

Add near the private helpers:

```elixir
defp reset_add_account(socket) do
  assign(socket,
    add_account_step: :closed,
    selected_provider: nil,
    selected_mailbox_id: nil
  )
end
```

- [ ] **Step 4: Render Back and Cancel controls**

At the bottom of `#add-account-panel`, after the three step branches, add:

```heex
<footer class="add-account-panel-footer">
  <button
    :if={@add_account_step != :account_type}
    id="back-add-account"
    type="button"
    class="settings-action"
    phx-click="back-add-account"
  >
    Back
  </button>
  <button
    id="cancel-add-account"
    type="button"
    class="settings-action"
    phx-click="cancel-add-account"
  >
    Cancel
  </button>
</footer>
```

- [ ] **Step 5: Add desktop styles after the existing settings action rules**

Add to `apps/manifold_web/assets/css/app.css`:

```css
.settings-intro {
  max-width: 620px;
  margin: 6px 0 0;
  color: #68717d;
}

.settings-heading-actions {
  display: flex;
  align-items: center;
  gap: 14px;
}

.settings-action-primary {
  border-color: #087f5b;
  background: #087f5b;
  color: #ffffff;
}

.settings-action-primary:hover,
.settings-action-primary:focus-visible {
  border-color: #075f47;
  background: #075f47;
  color: #ffffff;
}

.add-account-panel {
  max-width: 760px;
  margin: 28px 0;
  padding: 22px;
  border: 1px solid #b8cfc6;
  border-left: 4px solid #087f5b;
  border-radius: 8px;
  background: #fbfdfc;
  box-shadow: 0 14px 36px rgb(40 62 54 / 9%);
}

.add-account-panel-header,
.add-account-panel-footer {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
}

.add-account-panel-header h2 {
  margin: 2px 0 0;
}

.add-account-step {
  color: #087f5b;
  font-size: 12px;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}

.add-account-choices {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 12px;
}

.add-account-choice {
  display: flex;
  width: 100%;
  min-height: 82px;
  align-items: center;
  gap: 12px;
  padding: 14px;
  border: 1px solid #b8c0ca;
  border-radius: 7px;
  background: #ffffff;
  color: #34404d;
  text-align: left;
  cursor: pointer;
}

.add-account-choice:hover,
.add-account-choice:focus-visible {
  border-color: #087f5b;
  box-shadow: 0 0 0 3px rgb(8 127 91 / 12%);
  outline: none;
}

.add-account-choice:disabled {
  border-color: #d9dee4;
  background: #f4f6f8;
  color: #7b8490;
  cursor: not-allowed;
  box-shadow: none;
}

.add-account-choice el-dm-mdi {
  width: 26px;
  height: 26px;
  flex: 0 0 auto;
}

.add-account-choice strong,
.add-account-choice small {
  display: block;
}

.add-account-choice small {
  margin-top: 3px;
  color: #68717d;
}

#add-account-mailbox-form {
  display: grid;
  max-width: 460px;
  gap: 6px;
  margin: 18px 0;
}

#add-account-mailbox-form select {
  min-height: 42px;
}

.add-account-panel-footer {
  justify-content: flex-start;
  margin-top: 20px;
  padding-top: 16px;
  border-top: 1px solid #dfe8e4;
}
```

- [ ] **Step 6: Add narrow-screen styles**

Inside the existing narrow-screen media query that contains
`.settings-heading`, add:

```css
.settings-heading-actions {
  width: 100%;
  flex-wrap: wrap;
  justify-content: space-between;
}

.add-account-panel {
  margin: 20px 0;
  padding: 18px;
}

.add-account-choices {
  grid-template-columns: 1fr;
}
```

- [ ] **Step 7: Format and run complete scoped verification**

Run:

```bash
mix format \
  apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
mix test apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
mix compile --warnings-as-errors
git diff --check
```

Expected: the scoped test file passes with zero failures, compilation succeeds
without warnings, and `git diff --check` prints nothing.

- [ ] **Step 8: Review the scoped diff against the design**

Run:

```bash
git diff -- \
  apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/assets/css/app.css
```

Confirm:

- The per-mailbox connector table is absent.
- Gmail and Microsoft 365 are always visible in the provider step.
- Unconfigured providers cannot be selected.
- Only IDs from active mailboxes can become the OAuth destination.
- Back moves one step and Cancel resets all temporary state.
- LiveView does not call provider APIs.
- Existing connected-account sync and disconnect behavior is unchanged.

- [ ] **Step 9: Commit the completed interface**

```bash
git add \
  apps/manifold_web/lib/manifold_web/live/external_account_live/index.ex \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/assets/css/app.css
git commit -m "feat(web): finish add account interface"
```

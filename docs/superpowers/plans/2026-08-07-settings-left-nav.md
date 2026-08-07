# Settings Left Nav Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings left nav (General / Accounts / Appearance) shared across all `/settings/*` pages, redirect `/settings` → `/settings/general`, and ship General/Appearance as placeholders while keeping Accounts behavior unchanged.

**Architecture:** Split Settings into `live_session :settings` with `layout: {ManifoldWeb.Layouts, :settings}` and an `on_mount` hook that assigns `:settings_section` from the URL path. The settings layout mirrors the existing app chrome (appbar) and wraps `@inner_content` in a left-nav shell visually aligned with Operations (`ops_shell`). New `SettingsLive.General` / `SettingsLive.Appearance` placeholders; existing Account LiveViews stay as-is aside from living in the settings session.

**Tech Stack:** Elixir, Phoenix LiveView + VerifiedRoutes, phoenix_duskmoon tokens/CSS, ExUnit + `Phoenix.LiveViewTest`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-07-settings-left-nav-design.md`
- Shell only: General / Appearance are placeholders (no real settings fields; do not move theme switcher)
- `/settings` redirects to `/settings/general`
- All `/settings/*` routes share the left nav; `/settings/accounts…` highlights Accounts
- Styling: duskmoon tokens only (mirror `ops-*` patterns); responsive via CSS only
- Deep links like Mail “Manage accounts” keep `/settings/accounts*`
- Run tests via `devenv shell -- mix test …` unless already inside devenv
- Prefer TDD: failing test → implement → pass → commit per task
- After feature lands, update `.agents/skills/develop/references/settings-left-nav.md`
- Run `mix format` on touched Elixir files before each commit

---

## File Map

| Path | Responsibility |
| --- | --- |
| Create: `apps/manifold_web/lib/manifold_web/hooks/settings_path.ex` | `on_mount` + `handle_params` hook → assign `:settings_section` |
| Create: `apps/manifold_web/lib/manifold_web/components/settings_components.ex` | `settings_nav/1` (and optional thin shell helper used by layout) |
| Create: `apps/manifold_web/lib/manifold_web/components/layouts/settings.html.heex` | App chrome + left nav + `@inner_content` |
| Create: `apps/manifold_web/lib/manifold_web/live/settings_live/general.ex` | General placeholder LiveView |
| Create: `apps/manifold_web/lib/manifold_web/live/settings_live/appearance.ex` | Appearance placeholder LiveView |
| Create: `apps/manifold_web/lib/manifold_web/controllers/settings_redirect_controller.ex` | `GET /settings` → redirect to general |
| Modify: `apps/manifold_web/lib/manifold_web/router.ex` | Redirect route; `live_session :settings`; move settings lives |
| Modify: `apps/manifold_web/lib/manifold_web/components/layouts/app.html.heex` | Appbar Settings → `~p"/settings"` |
| Modify: `apps/manifold_web/assets/css/app.css` | `settings-layout` / nav styles (ops-like); exclude from centered content rule; responsive |
| Create: `apps/manifold_web/test/manifold_web/settings_live_test.exs` | Redirect, placeholders, nav active states |
| Modify: `apps/manifold_web/test/manifold_web/account_live_test.exs` | Assert sidebar present + Accounts active on index + one nested page |
| Create: `.agents/skills/develop/references/settings-left-nav.md` | Feature skill note |

---

### Task 1: Redirect + General placeholder (failing tests first)

**Files:**
- Create: `apps/manifold_web/test/manifold_web/settings_live_test.exs`
- Create: `apps/manifold_web/lib/manifold_web/controllers/settings_redirect_controller.ex`
- Create: `apps/manifold_web/lib/manifold_web/live/settings_live/general.ex`
- Modify: `apps/manifold_web/lib/manifold_web/router.ex`

**Interfaces:**
- Consumes: `ManifoldWeb.ConnCase`, `Phoenix.LiveViewTest`, existing `:browser` pipeline
- Produces:
  - `ManifoldWeb.SettingsRedirectController.redirect_general/2`
  - `ManifoldWeb.SettingsLive.General` LiveView at `/settings/general`
  - Router: `get "/settings", …` and `live "/settings/general", …`

- [ ] **Step 1: Write the failing tests**

Create `apps/manifold_web/test/manifold_web/settings_live_test.exs`:

```elixir
defmodule ManifoldWeb.SettingsLiveTest do
  use ManifoldWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "GET /settings redirects to /settings/general", %{conn: conn} do
    conn = get(conn, ~p"/settings")
    assert redirected_to(conn) == ~p"/settings/general"
  end

  test "general settings page renders placeholder and nav links", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/settings/general")

    assert html =~ "General"
    assert html =~ "Coming soon"
    assert html =~ ~p"/settings/general"
    assert html =~ ~p"/settings/accounts"
    assert html =~ ~p"/settings/appearance"
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/settings_live_test.exs`

Expected: FAIL — route `/settings` and/or `/settings/general` missing (CompileError / Router mismatch / live failed)

- [ ] **Step 3: Minimal redirect controller + General LiveView + routes**

`settings_redirect_controller.ex`:

```elixir
defmodule ManifoldWeb.SettingsRedirectController do
  use ManifoldWeb, :controller

  def redirect_general(conn, _params) do
    redirect(conn, to: ~p"/settings/general")
  end
end
```

`settings_live/general.ex` (temporary bare page — nav chrome lands in Task 2):

```elixir
defmodule ManifoldWeb.SettingsLive.General do
  use ManifoldWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "General")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>General</h1>
          <p class="settings-intro">Coming soon</p>
        </div>
      </div>
    </section>
    """
  end
end
```

In `router.ex`, inside the existing `scope "/", ManifoldWeb` / `:browser` pipeline, **keep** `live_session :local_instance` for now but **add** the redirect and general live inside that session temporarily so tests can pass before the settings layout split:

```elixir
get("/settings", SettingsRedirectController, :redirect_general)

live_session :local_instance do
  # ...existing non-settings routes...

  live("/settings/general", SettingsLive.General, :index)

  live("/settings/accounts", AccountLive.Index, :index)
  # ...rest of existing settings/accounts routes unchanged...
end
```

(Appearance + layout session split happen in later tasks. General test’s nav-link assertions will still fail until Task 2 adds the sidebar — **narrow Task 1 assertions if needed**.)

If Step 1’s general test already asserts nav hrefs, either:

- keep those assertions and expect Task 1 to only make the redirect test pass + general heading/placeholder pass; **edit the general test for Task 1** to:

```elixir
test "general settings page renders placeholder", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/settings/general")
  assert html =~ "General"
  assert html =~ "Coming soon"
end
```

and move nav-link assertions to Task 2.

- [ ] **Step 4: Re-run Task 1 tests**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/settings_live_test.exs`

Expected: PASS (redirect + general placeholder)

- [ ] **Step 5: Commit**

```bash
git add \
  apps/manifold_web/test/manifold_web/settings_live_test.exs \
  apps/manifold_web/lib/manifold_web/controllers/settings_redirect_controller.ex \
  apps/manifold_web/lib/manifold_web/live/settings_live/general.ex \
  apps/manifold_web/lib/manifold_web/router.ex
git commit -m "$(cat <<'EOF'
feat(web): add /settings redirect and General placeholder

EOF
)"
```

---

### Task 2: Settings path hook, nav component, settings layout, CSS

**Files:**
- Create: `apps/manifold_web/lib/manifold_web/hooks/settings_path.ex`
- Create: `apps/manifold_web/lib/manifold_web/components/settings_components.ex`
- Create: `apps/manifold_web/lib/manifold_web/components/layouts/settings.html.heex`
- Modify: `apps/manifold_web/lib/manifold_web/components/layouts.ex` (only if import needed; `embed_templates` already picks up `settings.html.heex`)
- Modify: `apps/manifold_web/lib/manifold_web/router.ex`
- Modify: `apps/manifold_web/assets/css/app.css`
- Modify: `apps/manifold_web/test/manifold_web/settings_live_test.exs`

**Interfaces:**
- Consumes: URL path from LiveView `handle_params`
- Produces:
  - `ManifoldWeb.Hooks.SettingsPath.on_mount(:default, params, session, socket)` → assigns `:settings_section` as `:general | :accounts | :appearance`
  - `ManifoldWeb.SettingsComponents.settings_nav/1` with `attr :current, :atom, required: true, values: [:general, :accounts, :appearance]`
  - Layout `{ManifoldWeb.Layouts, :settings}` rendering nav + `@inner_content`
  - `live_session :settings, on_mount: [ManifoldWeb.Hooks.SettingsPath], layout: {ManifoldWeb.Layouts, :settings}`

- [ ] **Step 1: Extend failing nav assertions**

Add to `settings_live_test.exs`:

```elixir
test "general settings page renders left nav with General current", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/settings/general")

  assert html =~ ~s(id="settings-nav")
  assert html =~ ~p"/settings/general"
  assert html =~ ~p"/settings/accounts"
  assert html =~ ~p"/settings/appearance"
  assert html =~ ~s(data-current="general")
end
```

- [ ] **Step 2: Run to verify failure**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/settings_live_test.exs`

Expected: FAIL — missing `settings-nav` / `data-current`

- [ ] **Step 3: Implement hook**

`hooks/settings_path.ex`:

```elixir
defmodule ManifoldWeb.Hooks.SettingsPath do
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView

  def on_mount(:default, _params, _session, socket) do
    socket =
      attach_hook(socket, :settings_section, :handle_params, fn _params, url, socket ->
        {:cont, assign(socket, :settings_section, section_from_path(URI.parse(url).path))}
      end)

    {:cont, socket}
  end

  defp section_from_path("/settings/general"), do: :general
  defp section_from_path("/settings/appearance"), do: :appearance
  defp section_from_path("/settings/accounts" <> _), do: :accounts
  defp section_from_path(_), do: :general
end
```

- [ ] **Step 4: Implement `settings_nav`**

`components/settings_components.ex`:

```elixir
defmodule ManifoldWeb.SettingsComponents do
  @moduledoc false

  use ManifoldWeb, :html

  attr(:current, :atom, required: true, values: [:general, :accounts, :appearance])

  def settings_nav(assigns) do
    ~H"""
    <aside class="settings-nav-aside" aria-label="Settings">
      <p class="settings-nav-title">Settings</p>
      <nav id="settings-nav" class="settings-nav-list" data-current={@current}>
        <.link
          navigate={~p"/settings/general"}
          class={["settings-nav-link", @current == :general && "is-current"]}
        >
          <.dm_mdi name="cog-outline" class="settings-nav-icon" />
          <span>General</span>
        </.link>
        <.link
          navigate={~p"/settings/accounts"}
          class={["settings-nav-link", @current == :accounts && "is-current"]}
        >
          <.dm_mdi name="account-multiple-outline" class="settings-nav-icon" />
          <span>Accounts</span>
        </.link>
        <.link
          navigate={~p"/settings/appearance"}
          class={["settings-nav-link", @current == :appearance && "is-current"]}
        >
          <.dm_mdi name="palette-outline" class="settings-nav-icon" />
          <span>Appearance</span>
        </.link>
      </nav>
    </aside>
    """
  end
end
```

- [ ] **Step 5: Implement `settings.html.heex`**

Copy structure from `app.html.heex`, then wrap main content:

```heex
<div class="app-shell min-h-screen bg-surface text-on-surface">
  <.dm_appbar
    id="app-appbar"
    title="Manifold"
    title_to={~p"/"}
    class="appbar-primary appbar-sticky"
    nav_label="Application"
  >
    <:logo>
      <.dm_mdi name="email-multiple-outline" class="brand-icon size-6" />
    </:logo>
    <:menu to={~p"/"}>Mail</:menu>
    <:menu to={~p"/deliveries"}>Operations</:menu>
    <:menu to={~p"/cloud"}>Cloud</:menu>
    <:menu to={~p"/settings"}>Settings</:menu>
    <:user_profile>
      <.dm_theme_switcher id="app-theme-switcher" phx-update="ignore" />
    </:user_profile>
  </.dm_appbar>
  <main class="content">
    <.flash_group flash={@flash} />
    <section class="settings-layout">
      <ManifoldWeb.SettingsComponents.settings_nav current={@settings_section} />
      <div class="settings-main">
        {@inner_content}
      </div>
    </section>
  </main>
</div>
```

Note: Layouts module uses `use ManifoldWeb, :html` via embed — if calling the component as above is awkward in the template, `import ManifoldWeb.SettingsComponents` inside `Layouts` by changing `layouts.ex` to:

```elixir
defmodule ManifoldWeb.Layouts do
  use ManifoldWeb, :html
  import ManifoldWeb.SettingsComponents
  embed_templates("layouts/*")
end
```

and use `<.settings_nav current={@settings_section} />`.

Ensure Theme hook still runs: it is attached in `use ManifoldWeb, :live_view` (`on_mount`), independent of `live_session` hooks.

- [ ] **Step 6: Split `live_session :settings` in router**

Move **all** settings lives (including General) out of `:local_instance` into:

```elixir
live_session :settings,
  on_mount: [ManifoldWeb.Hooks.SettingsPath],
  layout: {ManifoldWeb.Layouts, :settings} do
  live("/settings/general", SettingsLive.General, :index)

  live("/settings/accounts", AccountLive.Index, :index)
  live("/settings/accounts/new", AccountLive.New, :new)
  live("/settings/accounts/:id/edit", AccountLive.Edit, :edit)
  live("/settings/accounts/:id/receive_methods/new", AccountLive.ReceiveMethodNew, :new)
  live("/settings/accounts/:id/send_methods/new", AccountLive.SendMethodNew, :new)
  live("/settings/accounts/:id", AccountLive.Show, :show)
  live("/settings/accounts/:id/activity", ExternalAccountLive.Activity, :show)
end
```

Keep `get("/settings", SettingsRedirectController, :redirect_general)` **outside** live_sessions (controller redirect).

Leave Mail/Operations/Cloud/Jobs in `:local_instance`.

- [ ] **Step 7: Add CSS (mirror ops, do not reuse ops class names)**

Near `.ops-layout` / content rules in `app.css`:

1. Update the centered-content exclusion:

```css
.content > section:not(.webmail):not(.ops-layout):not(.settings-layout) {
  max-width: 1180px;
  margin: 0 auto;
  padding: 28px;
}
```

2. Add settings layout rules patterned after ops (tokens only):

```css
.settings-layout {
  display: grid;
  grid-template-columns: 220px minmax(0, 1fr);
  min-height: calc(100vh - 64px);
  background: var(--color-surface);
  color: var(--color-on-surface);
}

.settings-nav-aside {
  display: flex;
  min-width: 0;
  flex-direction: column;
  gap: 12px;
  padding: 20px 12px;
  border-right: 1px solid var(--color-outline-variant);
  background: var(--color-secondary);
  color: var(--color-secondary-content);
}

.settings-nav-title {
  margin: 0 9px 4px;
  color: color-mix(in oklch, var(--color-secondary-content) 72%, transparent);
  font-size: 12px;
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}

.settings-nav-list {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.settings-nav-link {
  display: grid;
  grid-template-columns: 22px minmax(0, 1fr);
  min-height: 38px;
  align-items: center;
  gap: 7px;
  padding: 0 9px;
  border-radius: var(--radius-field, 0.375rem);
  color: color-mix(in oklch, var(--color-secondary-content) 82%, transparent);
  font-size: 14px;
  text-decoration: none;
}

.settings-nav-link:hover {
  background: color-mix(in oklch, var(--color-secondary-content) 12%, transparent);
  color: var(--color-secondary-content);
}

.settings-nav-link.is-current {
  background: var(--color-primary-container);
  color: var(--color-on-primary-container);
  font-weight: 700;
}

.settings-nav-icon {
  width: 19px;
  height: 19px;
  color: currentColor;
}

.settings-main {
  min-width: 0;
  max-width: 1180px;
  padding: 28px;
}

/* Retire unused horizontal tab styles if still present as .settings-nav { display:flex; flex-wrap...}
   Remove or rename the old `.settings-nav` / `.settings-nav a` rules so they do not clash. */
```

In the existing `@media (max-width: …)` block that already collapses `.ops-layout`, add matching rules:

```css
.settings-layout {
  grid-template-columns: 1fr;
}

.settings-nav-aside {
  border-right: 0;
  border-bottom: 1px solid var(--color-outline-variant);
}

.settings-nav-list {
  flex-direction: row;
  flex-wrap: wrap;
}

.settings-main {
  max-width: none;
  padding: 20px 16px;
}
```

- [ ] **Step 8: Re-run settings tests**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/settings_live_test.exs`

Expected: PASS

Also smoke: `devenv shell -- mix test apps/manifold_web/test/manifold_web/account_live_test.exs`

Expected: PASS (layout change should not break account flows)

- [ ] **Step 9: Commit**

```bash
git add \
  apps/manifold_web/lib/manifold_web/hooks/settings_path.ex \
  apps/manifold_web/lib/manifold_web/components/settings_components.ex \
  apps/manifold_web/lib/manifold_web/components/layouts/settings.html.heex \
  apps/manifold_web/lib/manifold_web/components/layouts.ex \
  apps/manifold_web/lib/manifold_web/router.ex \
  apps/manifold_web/assets/css/app.css \
  apps/manifold_web/test/manifold_web/settings_live_test.exs
git commit -m "$(cat <<'EOF'
feat(web): add settings layout and left nav shell

EOF
)"
```

---

### Task 3: Appearance placeholder + appbar Settings link

**Files:**
- Create: `apps/manifold_web/lib/manifold_web/live/settings_live/appearance.ex`
- Modify: `apps/manifold_web/lib/manifold_web/router.ex`
- Modify: `apps/manifold_web/lib/manifold_web/components/layouts/app.html.heex`
- Modify: `apps/manifold_web/test/manifold_web/settings_live_test.exs`

**Interfaces:**
- Consumes: settings layout / `:settings_section` from Task 2
- Produces: `SettingsLive.Appearance` at `/settings/appearance`; appbar Settings → `/settings`

- [ ] **Step 1: Write failing tests**

```elixir
test "appearance settings page renders placeholder with Appearance current", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/settings/appearance")

  assert html =~ "Appearance"
  assert html =~ "Coming soon"
  assert html =~ ~s(id="settings-nav")
  assert html =~ ~s(data-current="appearance")
end

test "appbar Settings menu points at /settings", %{conn: conn} do
  {:ok, _view, html} = live(conn, ~p"/settings/general")
  assert html =~ ~s(href="/settings")
end
```

(If `dm_appbar` encodes the menu href differently, assert with `~p"/settings"` substring / menu label “Settings” as the suite already does for theme switcher elsewhere.)

- [ ] **Step 2: Run to verify failure**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/settings_live_test.exs`

Expected: FAIL — `/settings/appearance` missing and/or appbar still `/settings/accounts`

- [ ] **Step 3: Implement Appearance LiveView + route + appbar**

`appearance.ex` (same shape as General):

```elixir
defmodule ManifoldWeb.SettingsLive.Appearance do
  use ManifoldWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Appearance")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <div class="settings-heading">
        <div>
          <h1>Appearance</h1>
          <p class="settings-intro">Coming soon</p>
        </div>
      </div>
    </section>
    """
  end
end
```

Router inside `:settings` session:

```elixir
live("/settings/appearance", SettingsLive.Appearance, :index)
```

In **both** `app.html.heex` and `settings.html.heex`:

```heex
<:menu to={~p"/settings"}>Settings</:menu>
```

- [ ] **Step 4: Re-run tests**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/settings_live_test.exs`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add \
  apps/manifold_web/lib/manifold_web/live/settings_live/appearance.ex \
  apps/manifold_web/lib/manifold_web/router.ex \
  apps/manifold_web/lib/manifold_web/components/layouts/app.html.heex \
  apps/manifold_web/lib/manifold_web/components/layouts/settings.html.heex \
  apps/manifold_web/test/manifold_web/settings_live_test.exs
git commit -m "$(cat <<'EOF'
feat(web): add Appearance settings placeholder

EOF
)"
```

---

### Task 4: Accounts pages show nav with Accounts active

**Files:**
- Modify: `apps/manifold_web/test/manifold_web/account_live_test.exs`

**Interfaces:**
- Consumes: settings layout already wrapping Account LiveViews from Task 2
- Produces: regression coverage that index + nested show render `#settings-nav` with `data-current="accounts"`

- [ ] **Step 1: Write failing assertions (if not already true)**

Add to `account_live_test.exs`:

```elixir
test "accounts index and show render settings nav with Accounts current", %{conn: conn} do
  {:ok, account} =
    Accounts.create_account(%{name: "Nav", address: "nav@example.test"})

  {:ok, _view, html} = live(conn, ~p"/settings/accounts")
  assert html =~ ~s(id="settings-nav")
  assert html =~ ~s(data-current="accounts")

  {:ok, _view, html} = live(conn, ~p"/settings/accounts/#{account.id}")
  assert html =~ ~s(id="settings-nav")
  assert html =~ ~s(data-current="accounts")
end
```

- [ ] **Step 2: Run test**

Run: `devenv shell -- mix test apps/manifold_web/test/manifold_web/account_live_test.exs`

Expected: PASS if Task 2 wired accounts into `:settings` correctly; if FAIL, fix `SettingsPath.section_from_path/1` prefix match or router session membership — do **not** wrap each AccountLive render manually.

- [ ] **Step 3: Commit**

```bash
git add apps/manifold_web/test/manifold_web/account_live_test.exs
git commit -m "$(cat <<'EOF'
test(web): assert settings nav on accounts pages

EOF
)"
```

---

### Task 5: Skill reference + final verification

**Files:**
- Create: `.agents/skills/develop/references/settings-left-nav.md`

**Interfaces:**
- Consumes: shipped modules from Tasks 1–4
- Produces: develop-skill feature note for future agents

- [ ] **Step 1: Write skill reference**

```markdown
# Settings left nav

## Ownership
- Layout: `ManifoldWeb.Layouts` → `settings.html.heex`
- Nav: `ManifoldWeb.SettingsComponents.settings_nav/1`
- Path → section: `ManifoldWeb.Hooks.SettingsPath`
- Placeholders: `ManifoldWeb.SettingsLive.General`, `ManifoldWeb.SettingsLive.Appearance`
- Redirect: `ManifoldWeb.SettingsRedirectController`

## Routes
- `GET /settings` → `/settings/general`
- `/settings/general`, `/settings/appearance`, `/settings/accounts*` in `live_session :settings`

## Notes
- Visual pattern mirrors Operations `ops_shell` (tokens, grid, narrow-screen row nav)
- Theme switcher stays in appbar; Appearance is placeholder only
- Spec: `docs/superpowers/specs/2026-08-07-settings-left-nav-design.md`
```

- [ ] **Step 2: Final test pass + format**

Run:

```bash
devenv shell -- mix format \
  apps/manifold_web/lib/manifold_web/hooks/settings_path.ex \
  apps/manifold_web/lib/manifold_web/components/settings_components.ex \
  apps/manifold_web/lib/manifold_web/live/settings_live/general.ex \
  apps/manifold_web/lib/manifold_web/live/settings_live/appearance.ex \
  apps/manifold_web/lib/manifold_web/controllers/settings_redirect_controller.ex \
  apps/manifold_web/lib/manifold_web/router.ex \
  apps/manifold_web/lib/manifold_web/components/layouts.ex \
  apps/manifold_web/test/manifold_web/settings_live_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs

devenv shell -- mix test \
  apps/manifold_web/test/manifold_web/settings_live_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs
```

Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add .agents/skills/develop/references/settings-left-nav.md
git commit -m "$(cat <<'EOF'
docs: record settings left nav skill notes

EOF
)"
```

---

## Spec coverage checklist

| Spec requirement | Task |
| --- | --- |
| Left nav General / Accounts / Appearance | Task 2 |
| `/settings` → `/settings/general` | Task 1 |
| General / Appearance placeholders | Tasks 1, 3 |
| All settings routes share nav; Accounts prefix highlight | Tasks 2, 4 |
| Appbar Settings → `/settings` | Task 3 |
| Duskmoon tokens; CSS-only responsive | Task 2 |
| Accounts behavior unchanged | Tasks 2, 4 (existing tests) |
| Develop skill reference | Task 5 |

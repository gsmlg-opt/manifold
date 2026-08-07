# Settings Left Nav Design

**Date:** 2026-08-07  
**Status:** Approved for planning  
**Scope:** Settings shell — left sidebar (General / Accounts / Appearance), route redirect, placeholder pages. No real General/Appearance settings content.

## Goal

Give Settings a consistent left navigation with three sections:

1. **General** — placeholder
2. **Accounts** — existing account management UI (unchanged behavior)
3. **Appearance** — placeholder

Entering Settings lands on General. Every Settings route (including Accounts sub-pages) shares the same left nav.

## Decisions

| Decision | Choice |
| --- | --- |
| Scope | Navigation shell only; General / Appearance are placeholders |
| Default entry | `/settings` redirects to `/settings/general` |
| Sub-pages | All `/settings/*` routes use the shared left nav; Accounts sub-routes highlight Accounts |
| Layout approach | Shared `Layouts.settings` + `settings_nav` component (not per-page wrapping, not a single mega LiveView) |
| Theme switcher | Remains in appbar; Appearance page does not move it this iteration |
| Deep links | Mail “Manage accounts” and similar keep pointing at `/settings/accounts*` |

## Routes

| Path | LiveView / behavior |
| --- | --- |
| `/settings` | HTTP redirect → `/settings/general` |
| `/settings/general` | `SettingsLive.General` (placeholder) |
| `/settings/accounts` and existing nested routes | Existing `AccountLive.*` / `ExternalAccountLive.Activity` |
| `/settings/appearance` | `SettingsLive.Appearance` (placeholder) |

Appbar **Settings** menu item points to `/settings` (then redirects to General).

### Active nav rules

- Path `/settings/general` → highlight **General**
- Path starts with `/settings/accounts` → highlight **Accounts**
- Path `/settings/appearance` → highlight **Appearance**

## Architecture

```text
App shell (appbar)
  └─ Layouts.settings
       ├─ settings_nav (General | Accounts | Appearance)
       └─ @inner_content (page LiveView)
```

### Components

1. **`ManifoldWeb.Layouts.settings`**  
   Layout under the existing app shell: left sidebar + main content slot. Applied to all Settings LiveViews via router `live_session` (or equivalent layout option) so new Accounts sub-pages cannot omit the nav.

2. **`settings_nav` function component**  
   Three links; active state from current URI / path (prefix match for Accounts). Uses phoenix_duskmoon / design tokens only — no hardcoded palette colors for chrome.

3. **`SettingsLive.General` / `SettingsLive.Appearance`**  
   Minimal placeholder pages: heading + short “coming soon” style copy. No forms.

4. **Existing Accounts LiveViews**  
   Business logic and templates unchanged aside from attaching the settings layout (and any test updates for the new chrome).

### CSS

- Replace or extend the unused horizontal `.settings-nav` into a vertical `.settings-sidebar` / nav list using surface / primary / on-surface-variant tokens.
- Narrow viewports: sidebar becomes a compact horizontal strip (or simple wrap) via CSS only — no new JS hooks.

## Out of scope

- Real General settings fields
- Real Appearance controls (including moving theme switcher into Settings)
- Changing Accounts CRUD / connector flows
- Renaming or restructuring `AccountLive` modules beyond layout attachment

## Error handling & edge cases

| Case | Behavior |
| --- | --- |
| Visit `/settings` | Redirect to `/settings/general` |
| Unknown settings path | Existing Phoenix 404 behavior |
| Accounts empty / errors | Unchanged page behavior inside main pane |
| Direct deep link to account sub-page | Sidebar present; Accounts highlighted |

## Testing

- `/settings` redirects to `/settings/general`
- General and Appearance pages render the three nav links and placeholder copy
- Accounts index renders sidebar with Accounts active
- At least one Accounts nested page (e.g. show) renders sidebar with Accounts active
- Appbar Settings link targets `/settings`

## Acceptance criteria

- [ ] Left nav shows General, Accounts, Appearance on all Settings pages
- [ ] `/settings` → `/settings/general`
- [ ] General and Appearance are placeholders
- [ ] Accounts flows work as today inside the main pane
- [ ] Styling uses duskmoon tokens; responsive sidebar without new JS

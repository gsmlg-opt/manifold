# Settings left nav

## Ownership
- Layout: `ManifoldWeb.Layouts` → `settings.html.heex`
- Nav: `ManifoldWeb.SettingsComponents.settings_nav/1`
- Path → section: `ManifoldWeb.Hooks.SettingsPath`
- General placeholder: `ManifoldWeb.SettingsLive.General`
- Appearance/theme selector: `ManifoldWeb.SettingsLive.Appearance`
- Redirect: `ManifoldWeb.SettingsRedirectController`

## Routes
- `GET /settings` → `/settings/general`
- `/settings/general`, `/settings/appearance`, `/settings/oauth*`, `/settings/accounts*` in `live_session :settings`

## Notes
- Visual pattern mirrors Operations `ops_shell` (tokens, grid, narrow-screen row nav)
- Theme switcher lives only in Settings / Appearance; neither appbar layout renders it.
- Appearance uses `dm_segment_control` with `phx-hook="ThemePreference"` and `phx-update="ignore"`. System / Light / Dark map to `default` / `sunshine` / `moonlight` in `localStorage.theme`; the root antiflicker script restores the preference before paint.
- The client hook maintains one active segment and `aria-pressed`, saves changes immediately, and cleans up its delegated click listener on unmount. Native buttons support Tab and Enter/Space. The segmented control uses DuskMoon tokens for its surface, border, and selected background.
- `assets/js/app.js` owns a global system color-scheme listener so Auto follows system changes even outside Appearance. Explicit choices ignore system changes.
- OAuth routes use the OAuth current-section state and the key icon in the settings nav.
- `/settings/oauth/:provider/help` renders trusted provider setup instructions from the code-defined OAuth catalog and never loads credential values.
- Focused verification: `mix test apps/manifold_web/test/manifold_web/settings_live_test.exs apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs`
- Spec: `docs/superpowers/specs/2026-08-07-settings-left-nav-design.md`
- Theme relocation validation: scoped `settings_live_test.exs` and `cloud_live_test.exs`, JS sanity check, asset build, and browser checks for theme selection, navigation, refresh, and system Auto changes. No migration or configuration changes.

## Theme relocation validation (2026-10-07)
- PASS: 7 scoped ExUnit tests, changed-file formatter check, and asset build.
- PASS: `mix duskmoon_bundler.js.check` (0 errors; two existing unused catch-parameter warnings).
- PASS: browser selection of Sunshine/Moonlight, LiveView navigation and hard-refresh persistence, preference restoration on returning to Appearance, and Auto following both dark/light system changes outside Appearance (before replacing the dropdown with segments).
- Local validation required backing up an old untracked `priv/static/assets/js/app.js` to `/tmp/manifold-theme-old-assets/app.js`: it was served by `Plug.Static` ahead of the dev server and hid the current source. No tracked endpoint or dependency changes were needed.
- Follow-ups: none for the theme relocation.

## Segmented theme control validation (2026-10-07)
- Replaced the dropdown with the requested System / Light / Dark segmented control, with equal-width buttons and rounded token-based styling.
- PASS: 7 scoped settings/cloud tests, changed-file formatting, JS sanity check (0 errors; the same two existing warnings), and asset build.
- PASS: browser clicks, exclusive active/ARIA state, Tab/Enter/Space operation, navigation and refresh persistence, and System following OS changes outside Appearance. The control fits a 390px screen with all three buttons visible.
- Refreshed the untracked local `priv/static/assets/css/app.css` from the newly built CSS manifest for browser validation; its previous copy is backed up at `/tmp/manifold-theme-old-assets/app.css`.
- No database, API, environment, or dependency changes. No task follow-ups.

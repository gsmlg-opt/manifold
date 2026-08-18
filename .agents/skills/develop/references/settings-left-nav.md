# Settings left nav

## Ownership
- Layout: `ManifoldWeb.Layouts` → `settings.html.heex`
- Nav: `ManifoldWeb.SettingsComponents.settings_nav/1`
- Path → section: `ManifoldWeb.Hooks.SettingsPath`
- Placeholders: `ManifoldWeb.SettingsLive.General`, `ManifoldWeb.SettingsLive.Appearance`
- Redirect: `ManifoldWeb.SettingsRedirectController`

## Routes
- `GET /settings` → `/settings/general`
- `/settings/general`, `/settings/appearance`, `/settings/oauth*`, `/settings/accounts*` in `live_session :settings`

## Notes
- Visual pattern mirrors Operations `ops_shell` (tokens, grid, narrow-screen row nav)
- Theme switcher stays in appbar; Appearance is placeholder only
- OAuth routes use the OAuth current-section state and the key icon in the settings nav.
- `/settings/oauth/:provider/help` renders trusted provider setup instructions from the code-defined OAuth catalog and never loads credential values.
- Focused verification: `mix test apps/manifold_web/test/manifold_web/settings_live_test.exs apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs`
- Spec: `docs/superpowers/specs/2026-08-07-settings-left-nav-design.md`

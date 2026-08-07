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

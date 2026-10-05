# Microsoft device-code OAuth

- **Date:** 2026-10-06
- **Scope:** Microsoft work/school device login, public-client settings and refresh,
  compatible browser login, Settings/help, and Gmail setup guidance.
- **Operator instructions:** `docs/OAUTH_SETUP.md`.
- **Design:** `docs/superpowers/specs/2026-10-06-oauth-device-login-design.md`.

## Ownership and contracts

- `manifold_data`: `20261006000100_add_oauth_provider_auth_flow.exs` defaults old
  settings to `authorization_code` and constrains secret presence by mode;
  `20261006000200_create_oauth_device_transactions.exs` owns expiring device grants.
  Both refuse rollback while device-mode settings exist, before removing schema.
- `manifold_connectors`: `ProviderSettings` and `ProviderConfig` preserve legacy
  mode on omitted input, version/invalidate real changes, and resolve public
  clients without a secret. `DeviceOAuth.start/get/poll/cancel` encrypts private
  codes, respects provider pacing, bounds concurrent polling, and fences final
  persistence by cancellation, expiry, account lifecycle, and setting generation.
  `MicrosoftGraph` owns device transport and secret-free refresh.
  `OAuthAuthorizations.complete_token` reuses existing identity/address/scope and
  encrypted credential persistence. Direct `OAuth.start` rejects device clients.
- `manifold_web`: Microsoft Settings defaults to device mode only for new
  configurations. Existing browser clients remain intact until explicit switch.
  Help follows persisted mode. The start controller dispatches to
  `/settings/accounts/:id/microsoft/device?purpose=receive|send`. The dedicated
  LiveView starts only after an explicit action, uses asynchronous provider calls,
  and cancels timers/ignores late results on cancellation.

## Configuration and boundaries

Microsoft device mode uses Entra **Allow public client flows**, a client ID, and
delegated identity/mail scopes. No registered callback or client secret is needed.
The trusted token endpoint determines its sibling `devicecode` endpoint; Graph
operations still receive only sanitized operation configuration. Private device codes
never enter activity logs or browser assigns. Only the provider user code and
strictly allowlisted verification URI are exposed during login.

Switching mode increases the settings version and requires reconnect. Device mode
clears stored secrets; switching back requires a fresh secret. Same-mode unchanged
saves remain no-ops. Existing tokens/cipher contexts and Graph ingest boundaries
are preserved. Gmail keeps browser authorization with PKCE because Google's
device flow excludes Gmail permissions. Desktop-client loopback authorization is
not implemented; web-client localhost callbacks require the same browser/app host.

## Validation

**Verified 2026-10-06:** Formatting and strict development/test compilation
passed. The combined scoped gate passed 649 tests with zero failures: Data
migrations 6, Connectors 487, Outbound submission/provider 82, and Web
Settings/help/device/account 74. The real device-page test traverses mocked
Microsoft device/token/Graph endpoints and proves secret-free send completion;
a deterministic completion-before-cancel regression prevents a false cancelled
state. The development service was restarted, migrations applied, and Settings
plus both provider help pages returned HTTP 200 with the updated guidance.
Credentialed Microsoft tenant login was not run.

Scoped coverage includes settings/config/schema, device transport/lifecycle,
existing Microsoft/Gmail authorization and sync, Settings/help/account surfaces,
the actual device-page-to-Graph completion path, and migration up/down/up and
backfill/rollback guards. Local simulated-provider evidence does not establish
real Microsoft tenant login; credentialed staging remains operator work.

Use Devenv and an isolated test database. Relevant commands:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix compile --warnings-as-errors
mix test apps/manifold_connectors/test
mix test apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs apps/manifold_web/test/manifold_web/microsoft_device_live_test.exs apps/manifold_web/test/manifold_web/account_live_test.exs apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
mix test apps/manifold_data/test/manifold/migrations/add_oauth_device_flow_test.exs
```

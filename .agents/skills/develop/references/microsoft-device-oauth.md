# Microsoft device-code OAuth

- **Date:** 2026-10-06
- **Scope:** Microsoft work/school and personal Outlook.com device login, public-client settings and refresh,
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
not implemented. Gmail's Google login page accepts the full final redirect URL
when a web-client localhost callback cannot be reached; no forwarding is required.

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

## Personal account and verification URL repair (2026-10-09)

User-approved scope: support personal Outlook.com alongside work/school accounts,
without changing delegated scopes, address binding, encrypted persistence or
Graph operation credential boundaries.

- The default authority is now `common` in catalog, compile-time/runtime defaults
  and test tenant metadata; explicit trusted endpoint overrides remain available.
  Entra registration must allow organizational and personal Microsoft accounts.
- Device normalization accepts exactly `https://login.microsoft.com/device`, which
  was returned by the live provider with HTTP 200 but previously rejected locally.
  Legacy legitimate verification routes remain supported. HTTPS/443, no userinfo,
  query or fragment, and exact host/path checks continue to apply.
- Regression coverage traverses the real LiveView/device/Graph adapter with a
  mocked Outlook.com identity and the current verification URL; malicious variants
  of the new URL remain rejected. Help and operator setup describe both account types.
- No migration, new settings, environment variables or credentials are needed.
- Verified: 219 scoped tests, zero failures (Connectors 167, Web 38, runtime
  configuration 14). Changed-file formatting and strict development compilation
  passed. Expected RED reproduced the URL and default-authority failures before
  fixes; runtime regression expectations were also updated and verified.
- Independent adapter/integration and configuration/documentation reviews passed.
- Live public-client request used `/common/oauth2/v2.0/devicecode`; the real adapter
  successfully normalized `https://login.microsoft.com/device` with interval 5
  and expiry 900 seconds. Device-code encryption succeeded; codes were discarded
  without token polling or a new persisted login transaction.
- Service reload initially stalled with the old VM still listening. A targeted
  TERM to that old manifold VM plus managed restart started a new VM. Settings
  and Microsoft help returned HTTP 200 with common/personal-account guidance.
  Guarded pre-reload SyncAccount job recovery preserved existing work; Postgres
  was left running. The manager still reported starting at the final probe, while
  actual HTTP readiness was verified.
- Subsequent maintainer interactive login succeeded for a personal Outlook
  account. Live receive sync imported 258 messages. Work/school authorization and
  credentialed outbound sending were not exercised by this validation.

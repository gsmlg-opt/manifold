# OAuth provider settings

## Feature

- **Date:** 2026-08-18
- **Status:** implemented; live Google staging verification remains operator work
- **Design:** `docs/superpowers/specs/2026-08-18-oauth-provider-settings-design.md`
- **Plan:** `docs/superpowers/plans/2026-08-18-oauth-provider-settings.md`
- **Migration:** `20260818000100_add_oauth_provider_settings.exs`

## Ownership and routes

- `manifold_data` owns the migration at
  `apps/manifold_data/priv/repo/migrations/20260818000100_add_oauth_provider_settings.exs`.
- `manifold_connectors` owns
  `Manifold.Connectors.Schema.OAuthProviderSetting`,
  `Manifold.Connectors.OAuthProviderCatalog`,
  `Manifold.Connectors.OAuthProvider.Gmail`,
  `Manifold.Connectors.ProviderSettings`, and
  `Manifold.Connectors.ProviderConfig`.
- `manifold_web` owns `ManifoldWeb.SettingsLive.OAuth` at `/settings/oauth` and
  `ManifoldWeb.SettingsLive.OAuthHelp` at `/settings/oauth/:provider/help`.
  Gmail's concrete help route is `/settings/oauth/gmail/help`.
- The Google provider callback remains exactly
  `https://<host>/connectors/gmail/callback`, derived from the configured Phoenix
  Endpoint URL. Local development normally uses
  `http://localhost:4290/connectors/gmail/callback`.

The Settings routes inherit Manifold's trusted-local-instance boundary. They are
not administrator-authenticated and must not be exposed as a secure remote admin
surface without a separate access-control feature.

## Catalog contract and extension

`Manifold.Connectors.OAuthProviderCatalog.list/0` returns definitions in stable
display order and `fetch/1` rejects unknown keys. The Gmail definition in
`Manifold.Connectors.OAuthProvider.Gmail` supplies:

- stable `key`, display `name`, and `icon`;
- `callback_path` and supported `capabilities`;
- the exact trusted `scopes`;
- static, non-secret `runtime_config` endpoints;
- provider help title, checklist, scope purposes, testing/production notes, and
  official links.

The browser never accepts an arbitrary provider, endpoint, callback, or scope.
Endpoint override environment variables remain static operator/development
configuration and are allowlisted by the resolver.

To add a provider:

1. Add `Manifold.Connectors.OAuthProvider.<Provider>` with every definition field
   above and register it in `OAuthProviderCatalog.list/0` and `fetch/1`.
2. Add catalog and help-page tests for ordering, exact callback/scopes, official
   links, and rejection of unsupported keys.
3. Extend `ProviderConfig.fetch/1` and ensure credentials are resolved per
   operation rather than cached.
4. Implement provider-specific OAuth exchange, identity/scopes, refresh, receive,
   send, and dependent authorization/method lifecycle behavior.
5. Add migration only for genuinely provider-specific data. The generic
   `connector_oauth_provider_settings` table needs no schema change for another
   catalog provider.

Microsoft is intentionally unchanged and remains environment-backed until its own
catalog/lifecycle migration.

## Persistence and public APIs

`connector_oauth_provider_settings` has one row per provider with UUID `id`,
unique `provider`, plaintext `client_id`, encrypted
`client_secret_ciphertext`, `key_version`, `lock_version`, and UTC-microsecond
timestamps. The client ID is not secret because OAuth authorization URLs expose
it. The secret envelope uses the stable associated data:

```text
oauth_provider_setting:<setting-id>:client_secret
```

`MANIFOLD_CONNECTOR_ENCRYPTION_KEY` remains the stable, out-of-database master
key. The legacy `MANIFOLD_GMAIL_CLIENT_ID` and
`MANIFOLD_GMAIL_CLIENT_SECRET` variables are ignored, are not imported, and are
never a fallback.

The supported safe context API is:

- `Manifold.Connectors.list_oauth_provider_settings/0`
- `Manifold.Connectors.get_oauth_provider_setting/1`
- `Manifold.Connectors.change_oauth_provider_setting/2`
- `Manifold.Connectors.put_oauth_provider_setting/3`
- `Manifold.Connectors.remove_oauth_provider_setting/2`

Safe views contain provider, client ID, secret-present status, status, and lock
version; they never contain a secret or ciphertext. Runtime consumers use
`Manifold.Connectors.ProviderConfig.fetch/1`. The transaction-only
`ProviderSettings.lock_provider_for_transaction/1` and
`validate_generation_for_transaction/3` support final OAuth completion fencing
without returning plaintext credentials.

## Save, rotation, removal, and errors

- Initial save requires both client ID and secret and encrypts before persistence.
- With an unchanged client ID, a blank secret is a safe no-op that preserves the
  ciphertext. A nonblank secret rotates it.
- Changing the client ID requires a new secret.
- Every actual credential save, rotation, client-ID change, or removal marks
  existing Gmail authorizations and receive/send methods `reconnect_required` and
  disables the methods in the same transaction. Nothing resumes automatically.
- Removal deletes only the provider setting. Encrypted user grants remain local,
  and Manifold does not revoke access at Google.
- Save/removal effects are visible immediately; no process restart is required.
- Missing settings make Gmail unavailable. Undecryptable/corrupt settings fail
  closed as `provider_configuration_error`; stale form versions return
  `stale_oauth_provider_setting`.

All setting mutations take the provider-scoped PostgreSQL advisory transaction
lock, then lock the setting and affected lifecycle rows in a stable order. The UI
submits the expected `lock_version`, preventing silent overwrites.

## Resolver and OAuth generation fence

All Gmail consumers go through `Manifold.Connectors.ProviderConfig`: configured
receive/send provider discovery, OAuth start, authorization-code exchange and
identity lookup, access-token refresh, receive sync, send-method checkout, and
Gmail submission. There is no credential cache.

OAuth start snapshots `oauth_provider_setting_id` and
`oauth_provider_setting_lock_version` on `connector_oauth_transactions`.
Completion revalidates the snapshot before code exchange. External Google I/O is
performed without holding a database/advisory lock. The final persistence
transaction then takes the provider advisory lock and revalidates the same UUID,
lock version, and decryptability. A save, rotate, remove, or remove/recreate race
therefore ends as `provider_configuration_changed` and requires a fresh OAuth
start.

## Secret and observability invariants

- Plaintext client secrets and ciphertext never appear in browser HTML, retained
  LiveView assigns, changeset inspection, flash text, logs, telemetry, activity
  events, or public errors.
- The secret input always renders empty. Submitted secret material is cleared on
  validation and persistence errors.
- Credential structs redact secret inspection; safe view structs expose only the
  client ID and boolean secret state.
- OAuth/sync/submission telemetry uses bounded `provider_not_configured` for a
  missing setting and `provider_configuration_error` for corrupt runtime
  configuration, never crypto details or provider secrets.

## Non-rolling cutover and rollback

Before applying `20260818000100`, drain and stop every old Phoenix instance,
connector process, and Oban worker. Do not allow an old node to keep using the
removed environment client credentials while a new node reads database settings.
The migration performs no environment backfill. After migration Gmail is
unavailable until Google credentials are saved in Settings → OAuth, and all
existing Gmail grants require reconnect.

The down migration refuses before DDL when any provider setting exists or any
OAuth transaction has a setting UUID/version fence. Do not bypass this guard.

## Exact verification commands

```sh
devenv shell -- mix test apps/manifold_data/test
devenv shell -- mix test apps/manifold_connectors/test
devenv shell -- mix test \
  apps/manifold_web/test/manifold_web/settings_live_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/test/manifold_web/outbound_mail_live_test.exs

devenv shell -- mix format --check-formatted
devenv shell -- mix compile --warnings-as-errors
```

For a faster focused loop:

```sh
devenv shell -- mix test \
  apps/manifold_data/test/manifold/migrations/add_oauth_provider_settings_test.exs \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_connectors/test/manifold/connectors/schema/oauth_provider_setting_test.exs \
  apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs \
  apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs \
  apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs
```

## Browser and staging smoke

- [ ] With Gmail not configured, confirm both Add receive and Add send pickers
      show Gmail unavailable.
- [ ] Open `/settings/oauth/gmail/help`; verify the exact deployed callback, four
      scopes, testing note, production note, and official links.
- [ ] Save staging Google credentials and confirm both pickers enable immediately
      without restarting Phoenix or workers.
- [ ] Connect receive, complete an import, add/upgrade send, submit one message,
      and verify it through the approved staging Gmail identity.
- [ ] Submit a blank secret with unchanged client ID and confirm the connection is
      not disrupted.
- [ ] Rotate the secret and change the client ID with a new secret; confirm
      existing Gmail grants and methods require reconnect.
- [ ] Remove the setting and confirm Gmail disables immediately, no method resumes,
      stored grants remain local, and no Google revoke occurs.
- [ ] Use a unique sentinel secret and confirm it appears in neither rendered
      HTML, LiveView error output, logs, telemetry, nor database plaintext fields.

## Upstream UI issues

- `duskmoon-dev/phoenix-duskmoon-ui#142` tracks `dm_btn` confirmation Cancel not
  closing the registered dialog.
- `duskmoon-dev/phoenix-duskmoon-ui#143` tracks missing modal focus management in
  the `dm_btn` confirmation dialog.

OAuth settings currently uses a native submit button to preserve one-submit form
behavior and a native confirmed-removal button because of these dialog issues;
the removal callsite is marked with the `#143` workaround. When both upstream
fixes ship and the dependency is upgraded, re-test cancel, Escape, initial focus,
focus trapping/restoration, and one-submit behavior. Then replace the removal
button with `dm_btn` and remove the workaround comment; replace the submit button
only after its one-submit behavior is also verified.

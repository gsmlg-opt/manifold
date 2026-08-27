# OAuth provider settings

## Feature

- **Date:** 2026-08-18; Microsoft catalog adoption updated 2026-08-27
- **Status:** implemented; live Google and Microsoft staging verification remains
  operator work
- **Original design:** `docs/superpowers/specs/2026-08-18-oauth-provider-settings-design.md`
- **Microsoft design:** `docs/superpowers/specs/2026-08-27-microsoft-oauth-provider-settings-design.md`
- **Original plan:** `docs/superpowers/plans/2026-08-18-oauth-provider-settings.md`
- **Microsoft plan:** `docs/superpowers/plans/2026-08-27-microsoft-oauth-provider-settings.md`
- **Migration:** `20260818000100_add_oauth_provider_settings.exs`

## Ownership and routes

- `manifold_data` owns the migration at
  `apps/manifold_data/priv/repo/migrations/20260818000100_add_oauth_provider_settings.exs`.
- `manifold_connectors` owns
  `Manifold.Connectors.Schema.OAuthProviderSetting`,
  `Manifold.Connectors.OAuthProviderCatalog`,
  `Manifold.Connectors.OAuthProvider.Gmail`,
  `Manifold.Connectors.OAuthProvider.Microsoft`,
  `Manifold.Connectors.ProviderSettings`, and
  `Manifold.Connectors.ProviderConfig`.
- `manifold_web` owns `ManifoldWeb.SettingsLive.OAuth` at `/settings/oauth` and
  `ManifoldWeb.SettingsLive.OAuthHelp` at `/settings/oauth/:provider/help`.
  Concrete help routes are `/settings/oauth/gmail/help` and
  `/settings/oauth/microsoft/help`.
- Production callbacks remain exactly
  `https://<host>/connectors/gmail/callback` and
  `https://<host>/connectors/microsoft/callback`, derived from the configured
  Phoenix Endpoint URL. Local development callbacks are exactly
  `http://localhost:4290/connectors/gmail/callback` and
  `http://localhost:4290/connectors/microsoft/callback`.

The Settings routes inherit Manifold's trusted-local-instance boundary. They are
not administrator-authenticated and must not be exposed as a secure remote admin
surface without a separate access-control feature.

### OAuth card element registration

The OAuth settings and help pages render `dm_card` and `dm_badge`, which emit the
`el-dm-card` and `el-dm-badge` custom elements. Their registrations must remain
imported in `apps/manifold_web/assets/js/app.js`; an unregistered card defaults to
`display: inline` and fragments its border/background across the form. The shared
`oauth-provider-card` class provides the block-level width/margin contract, and
its `:not(:defined)` rule preserves a usable token-styled card while JavaScript is
unavailable. The focused OAuth LiveView test checks the imports, card class, and
fallback rule; browser verification must also confirm both elements are defined.

## Catalog contract and extension

`Manifold.Connectors.OAuthProviderCatalog.list/0` returns Gmail followed by
Microsoft in stable display order, and `fetch/1` rejects unknown keys. Definitions
in `Manifold.Connectors.OAuthProvider.Gmail` and
`Manifold.Connectors.OAuthProvider.Microsoft` supply:

- stable `key`, display `name`, and `icon`;
- `callback_path` and supported `capabilities`;
- the exact trusted `scopes`;
- static, non-secret `runtime_config` endpoints;
- provider help title, checklist, scope purposes, testing/production notes, and
  official links.

The browser never accepts an arbitrary provider, endpoint, callback, or scope.
Endpoint override environment variables remain static operator/development
configuration and are allowlisted by the resolver.

The catalog currently drives provider-setting validation/listing, the Settings
cards and help pages, and Gmail and Microsoft's non-secret runtime endpoint
defaults in `ProviderConfig`. Registering a module in the catalog does **not**
make a future provider usable for OAuth, account setup, receive sync, or outbound
submission. Those paths still contain explicit provider registries, guards,
ordering, labels, and database constraints.

### Complete provider-extension checklist

1. Add `Manifold.Connectors.OAuthProvider.<Provider>` with every definition field
   above and register it in
   `apps/manifold_connectors/lib/manifold/connectors/oauth_provider_catalog.ex` in
   `OAuthProviderCatalog.list/0` and `fetch/1`. Settings consumption is in
   `ProviderSettings` plus `SettingsLive.OAuth.load_providers/1` and
   `SettingsLive.OAuthHelp.mount/3`.
2. Extend
   `apps/manifold_connectors/lib/manifold/connectors/provider_config.ex` in
   `ProviderConfig.fetch/1`, including credential source and safe endpoint
   allowlisting. Do not cache resolved credentials.
3. Extend `apps/manifold_connectors/lib/manifold/connectors/oauth.ex`:
   `@providers`, the `authorization_url/6` provider case, transaction-generation
   validation when settings-backed, and the `required_scopes/2` path. Extend
   `apps/manifold_connectors/lib/manifold/connectors/oauth_scopes.ex` in
   `identity/1`, `purpose/2`, `method_scope/2`, and `approved?/2`.
4. Extend `apps/manifold_connectors/lib/manifold/connectors.ex` in every OAuth
   gate: `complete_authorization/4`,
   `checkout_resolved_oauth_access_token/5`, `configured_providers/0`,
   `checkout_send_method/3`, `disconnect_send_method/2`, `disconnect/1`,
   `delete_receive_method/1`, `oauth_method_scope/2`,
   `checkout_oauth_send_method/3`, `validate_oauth_method_snapshot/2`,
   `oauth_submission_config/2`, and `oauth_authorization_provider/1`. Add
   `adapter_config/1` and `completion_adapter_config/2` clauses and setting
   generation validation when the provider is database-backed.
5. Extend
   `apps/manifold_connectors/lib/manifold/connectors/oauth_authorizations.ex`:
   `@providers` and the guards in `complete/6`, `add_authorized_method/6`,
   `validate_checkout_authorization/2`, and both
   `do_method_authorization_id/2,3` forms. Implement provider-specific identity,
   cursor initialization, refresh, generation fencing, reconnect text, and
   lifecycle transitions.
6. Extend `apps/manifold_connectors/lib/manifold/connectors/sync.ex` in
   `runtime/1`, `auth_material/5`, `handle_account_provider_error/4`,
   `handle_cursor_provider_error/5`, `normalize_provider_error/2`,
   `oauth_provider_name/1`, and `lock_current_failure_authorization/2`. Add a
   receive adapter implementing the applicable callbacks in
   `Manifold.Connectors.Provider` when `:receive` is advertised.
7. Extend `apps/manifold_web/lib/manifold_web/controllers/connector_oauth_controller.ex`
   in `@providers` and `provider_name/1`. In
   `AccountLive.ReceiveMethodNew`, update `@oauth_providers`, the
   `choose-kind` guard, the explicit `gmail microsoft imap eas` display order,
   configured-provider disabling, icons, descriptions, headings, actions, and
   labels. In `AccountLive.SendMethodNew`, update `@oauth_providers`, the explicit
   Gmail → Microsoft → SMTP card order, disabled state, copy, headings, actions,
   and labels. Also update the `@oauth_providers` ordering plus labels/reconnect
   behavior in `AccountLive.Show`, and provider labels in `AccountLive.Index`.
8. Extend schema allowlists in
   `Schema.OAuthAuthorization`, `Schema.OAuthTransaction`,
   `Schema.ReceiveMethod.kinds/0` and `implemented_kinds/0`, and
   `Schema.SendMethod.kinds/0` as applicable. The generic
   `connector_oauth_provider_settings` table needs no provider-specific column,
   but a usable provider still needs a new migration for the OAuth authorization,
   transaction, receive/send-method, and outbound provider check constraints.
   Current constraints were established by
   `20260811000500_add_shared_gmail_authorizations.exs`,
   `20260812000200_add_shared_microsoft_authorizations.exs`, and
   `20260812000300_add_microsoft_provider_payloads.exs`; do not edit those applied
   migrations.
9. When `:send` is advertised, add the connector checkout/configuration path, an
   adapter in `apps/manifold_outbound/lib/manifold/outbound/provider/`, and update
   `Manifold.Outbound.Provider.adapter/1`,
   `Manifold.Outbound.Submission.provider_config/3` and
   `maybe_mark_oauth_reconnect/3`,
   `Manifold.Outbound.Schema.ProviderSubmission` validation, and matching database
   constraints. Preserve submission uncertainty and method snapshot fences.
10. Test the catalog/settings/help surface and every registry changed above. At a
    minimum run the catalog, provider-config, OAuth, both existing provider
    authorization, sync, account LiveView, OAuth settings LiveView, outbound
    submission, and provider-adapter suites; add provider-specific receive/send
    coverage for every advertised capability.

Use this existing-provider regression command when changing the extension
surface, then add the new provider's own test files:

```sh
devenv shell -- mix test \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs \
  apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_outbound/test/manifold/outbound/provider/gmail_test.exs \
  apps/manifold_outbound/test/manifold/outbound/provider/microsoft_graph_test.exs
```

Gmail and Microsoft are both catalog-backed. Microsoft credentials have no
environment source, import, or fallback; its tenant is fixed to `organizations`
for work/school accounts only. Only the Microsoft authorization URL, token URL,
and Graph base URL environment overrides remain.

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
never a fallback. Legacy Microsoft client-credential and tenant environment
values are likewise ignored, not imported, and never used as fallback.

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
- Every actual credential save, rotation, client-ID change, or removal marks the
  affected provider's authorizations and receive/send methods
  `reconnect_required` and disables the methods in the same transaction. Nothing
  resumes automatically.
- Removal deletes only the provider setting. Encrypted user grants remain local,
  and Manifold does not revoke access at Google or Microsoft.
- Save/removal effects are visible immediately; no process restart is required.
- Missing settings make the affected provider unavailable. Undecryptable/corrupt
  settings fail closed as `provider_configuration_error`; stale form versions
  return `stale_oauth_provider_setting`.

All setting mutations take the provider-scoped PostgreSQL advisory transaction
lock, then lock the setting and affected lifecycle rows in a stable order. The UI
submits the expected `lock_version`, preventing silent overwrites.

## Resolver and OAuth generation fence

All Google and Microsoft consumers go through
`Manifold.Connectors.ProviderConfig`: configured receive/send provider discovery,
OAuth start, authorization-code exchange and identity lookup, access-token
refresh, receive sync, send-method checkout, and provider submission. There is no
credential cache.

OAuth start snapshots `oauth_provider_setting_id` and
`oauth_provider_setting_lock_version` on `connector_oauth_transactions`.
After each provider's database-credential cutover, Google and Microsoft
transaction rows without both generation fields are atomically removed and
rejected as `provider_configuration_changed`, so a second consume is an OAuth
state mismatch. Initial provider-setting save starts the generation at one, and
every real credential rotation advances it. Completion revalidates the snapshot
before code exchange. External provider I/O is performed without holding a
database/advisory lock. The final persistence transaction then takes the provider
advisory lock and revalidates the same UUID, lock version, and decryptability. A
save, rotate, remove, or remove/recreate race therefore ends as
`provider_configuration_changed` and requires a fresh OAuth start.

## Secret and observability invariants

- Plaintext client secrets and ciphertext never appear in browser HTML, retained
  LiveView assigns, changeset inspection, flash text, logs, telemetry, activity
  events, or public errors.
- The secret input always renders empty. Submitted secret material is cleared on
  validation and persistence errors.
- A not-configured form accepts only a missing, `nil`, or empty lock-version
  value and maps it to an explicit missing-generation snapshot. Once a setting
  exists, the lock version is required and must be a positive PostgreSQL integer
  no greater than `2_147_483_647`.
- Validation changesets receive a secret-redacted focused patch. Every other
  rejected save—including stale, unsupported, malformed, database, and provider
  configuration errors—uses a generic-flash replacement navigation to a fresh
  OAuth LiveView, ensuring browser-local secret input cannot survive a no-op
  diff or add a duplicate OAuth entry to browser history.
- Credential structs redact secret inspection; safe view structs expose only the
  client ID and boolean secret state.
- OAuth/sync/submission telemetry uses bounded `provider_not_configured` for a
  missing setting and `provider_configuration_error` for corrupt runtime
  configuration, never crypto details or provider secrets.

## Non-rolling cutover and rollback

Before applying `20260818000100`, drain and stop every old Phoenix instance,
connector process, and Oban worker. That migration performs no environment import
or fallback; Gmail is unavailable until Google credentials are saved in Settings
→ OAuth, and existing Gmail grants require reconnect.

The 2026-08-27 Microsoft catalog adoption adds no migration. For its code-only,
non-rolling cutover, first stop new Microsoft submissions and drain all queued
and executing Microsoft send work, then drain the old Phoenix, connector, and
Oban processes before deploying the new binary. Only Microsoft is unavailable
until its Settings credentials are saved, and existing Microsoft grants and
methods require reconnect. The existing Google setting, grants, and methods stay
valid; do not rotate or remove Google credentials for this Microsoft cutover.

The down migration refuses before DDL when any provider setting exists or any
OAuth transaction has a setting UUID/version fence. The Settings UI removes only
the setting; consumed fenced transaction history still blocks rollback. Do not
delete rows based on this summary. Follow README's guarded rollback runbook for
backup/export, inspection, explicitly authorized transaction-history deletion,
development/release commands, and post-rollback verification.

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
  apps/manifold_data/test/manifold/config_test.exs \
  apps/manifold_data/test/manifold/migrations/add_oauth_provider_settings_test.exs \
  apps/manifold_connectors/test/manifold/connectors/oauth_provider_catalog_test.exs \
  apps/manifold_connectors/test/manifold/connectors/schema/oauth_provider_setting_test.exs \
  apps/manifold_connectors/test/manifold/connectors/provider_settings_test.exs \
  apps/manifold_connectors/test/manifold/connectors/provider_config_test.exs \
  apps/manifold_connectors/test/manifold/connectors/oauth_test.exs \
  apps/manifold_connectors/test/manifold/connectors/gmail_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/microsoft_authorizations_test.exs \
  apps/manifold_connectors/test/manifold/connectors/submission_method_test.exs \
  apps/manifold_connectors/test/manifold/connectors/sync_test.exs \
  apps/manifold_connectors/test/manifold/connectors_test.exs \
  apps/manifold_outbound/test/manifold/outbound/jobs/submit_outbound_test.exs \
  apps/manifold_outbound/test/manifold/outbound/submission_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs \
  apps/manifold_web/test/manifold_web/oauth_settings_live_test.exs
```

## Browser and staging smoke

- [ ] With Google and Microsoft not configured, confirm both Add receive and Add
      send pickers show each provider unavailable.
- [ ] Open both provider help routes; verify each exact deployed callback, scopes,
      testing note, production note, and official links.
- [ ] Save staging Google and Microsoft credentials and confirm both pickers
      enable immediately without restarting Phoenix or workers.
- [ ] For each provider, connect receive, complete an import, add/upgrade send,
      submit one message, and verify it through the approved staging identity.
- [ ] For each provider, submit a blank secret with unchanged client ID and
      confirm the connection is not disrupted.
- [ ] For each provider, rotate the secret and change the client ID with a new
      secret; confirm existing grants and methods require reconnect.
- [ ] Remove each setting and confirm that provider disables immediately, no
      method resumes, stored grants remain local, and no remote revoke occurs.
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

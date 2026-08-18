# OAuth Provider Settings Design

**Date:** 2026-08-18

**Status:** Approved design

**Scope:** Global OAuth application configuration in Settings, with Gmail as the first supported provider

## Summary

Manifold will add an **OAuth** section under Settings where operators configure
OAuth applications used by provider connectors. Configuration is global to the
Manifold installation, provider-specific, encrypted at rest, and effective
without restarting the application.

Gmail is the first supported settings provider. The design is intentionally
catalog-driven so future providers can reuse the same persistence, UI, secret
handling, rotation, removal, and help-page flow without schema changes.

Google OAuth client credentials will no longer be read from
`MANIFOLD_GMAIL_CLIENT_ID` or `MANIFOLD_GMAIL_CLIENT_SECRET`. There is no import,
fallback, or precedence relationship with those legacy variables.

## Goals

- Add an **OAuth** item to the Settings navigation.
- Configure Google OAuth client ID and client secret from the browser.
- Encrypt client secrets at rest and never return them to the browser.
- Make save, rotation, and removal effective immediately.
- Mark affected Gmail connections `reconnect_required` when provider credentials
  change or are removed.
- Route every Gmail OAuth, receive-sync, and send operation through one provider
  configuration resolver.
- Support additional code-defined OAuth provider modules later.
- Add a provider-specific help page that explains how to obtain credentials.

## Non-goals

- Arbitrary user-defined OAuth endpoints, scopes, or provider modules.
- Administrator authentication or role-based access control. The page inherits
  the current trusted-local Settings boundary.
- Importing Google credentials from legacy environment variables.
- Revoking OAuth grants at Google when local configuration is removed.
- Migrating Microsoft OAuth configuration in this change. Microsoft can join the
  provider catalog in a later feature.
- Caching provider credentials in a GenServer, ETS table, or application env.

## Provider Catalog

OAuth providers are defined by trusted application code. A provider catalog entry
supplies:

- stable provider key;
- display name and icon;
- callback path;
- credential field definitions;
- authorization, token, user-info, and API endpoints;
- supported capabilities and required scopes;
- provider-specific help content and official documentation links.

The initial catalog contains only `gmail`. Users cannot persist an unsupported
provider or override endpoints and scopes from the UI. Adding a future provider
requires a code change and tests, but does not require a new settings table.

## Persistence

Create `connector_oauth_provider_settings`, owned by `manifold_connectors` with
its migration in `manifold_data`.

| Column | Type | Notes |
| --- | --- | --- |
| `id` | UUID | Primary key |
| `provider` | text | Unique, non-empty provider key; application validates catalog membership |
| `client_id` | text | Required, trimmed, stored plaintext |
| `client_secret_ciphertext` | binary | Required encrypted envelope |
| `key_version` | integer | Encryption-key version, initially `1` |
| `lock_version` | integer | Optimistic/concurrency version |
| timestamps | UTC microseconds | Standard audit timestamps |

The client ID is not treated as a secret because it is included in browser OAuth
authorization requests. The client secret is encrypted with the existing
connector AES-256-GCM helper and stable associated data:

```text
oauth_provider_setting:<setting-id>:client_secret
```

`MANIFOLD_CONNECTOR_ENCRYPTION_KEY` remains the out-of-database master key. It is
not an OAuth provider credential and must not be stored beside the ciphertext.

Row existence means the provider is configured only when the catalog contains
that provider, the row is valid, and the secret decrypts successfully. Corrupt
or undecryptable configuration fails
closed and is reported as a configuration error without exposing ciphertext,
secret text, or crypto details.

## Connector Boundaries

`Manifold.Connectors.ProviderSettings` owns validation, encryption, persistence,
rotation, removal, and lifecycle effects. Public `Manifold.Connectors` functions
expose safe view models and changesets but never decrypted secrets.

A single provider configuration resolver combines:

- database-backed client ID and decrypted client secret; and
- code-defined, non-secret catalog endpoints, adapter, capabilities, and scopes.

Every Gmail consumer must use this resolver:

- configured-provider discovery for receive/send method pickers;
- OAuth authorization start;
- authorization-code exchange and identity lookup;
- access-token refresh;
- receive synchronization;
- Gmail send-method checkout and submission.

There is no cache. Each operation resolves the current row so changes take effect
without a process restart and cannot leave background workers on stale
application configuration.

## Save, Rotation, and Removal

All mutations lock the provider setting and affected Gmail lifecycle rows in a
stable order inside one database transaction.

### Initial save

- Both client ID and client secret are required.
- The secret is encrypted before persistence.
- If Gmail authorizations already exist from the legacy environment-based era,
  they are marked `reconnect_required`; Manifold does not assume the newly entered
  application owns their refresh tokens.
- Unfinished Gmail OAuth transactions are invalidated.

### Update with unchanged client ID

- A blank secret preserves the existing ciphertext.
- A nonblank secret rotates the secret.
- Secret rotation marks existing Gmail authorizations and methods
  `reconnect_required`, because the previous secret may no longer exchange or
  refresh tokens.
- Unfinished Gmail OAuth transactions are invalidated.

### Update with changed client ID

- A new nonblank secret is mandatory.
- Existing Gmail authorizations and receive/send methods are marked
  `reconnect_required` and disabled.
- Unfinished Gmail OAuth transactions are invalidated.

### Removal

- Removal is a separate confirmed action, never inferred from blank fields.
- The provider setting row is deleted.
- Existing Gmail authorizations and receive/send methods are marked
  `reconnect_required` and disabled.
- Unfinished Gmail OAuth transactions are invalidated.
- Existing encrypted user grants remain stored locally. Manifold does not revoke
  access at Google.

## OAuth Transaction Version Fence

OAuth transactions snapshot the provider-setting `lock_version` at authorization
start. Callback consumption requires the same version. If credentials were saved,
rotated, or removed while consent was in flight, completion fails with a generic
`provider_configuration_changed` result and the user must restart authorization.

This closes the race where an authorization code created for one client could be
exchanged using another client configuration.

## Settings UI

Add `/settings/oauth` as `SettingsLive.OAuth` and add **OAuth** to the existing
left Settings navigation and current-section hook.

The page renders provider cards from the catalog. The Gmail card contains:

- status badge: **Configured**, **Not configured**, or **Configuration error**;
- client ID text input;
- empty client secret password input;
- “Leave blank to keep the current secret” when configured;
- read-only, copyable callback URI derived from the current endpoint;
- **Save changes** primary action;
- **Remove configuration** destructive action when configured;
- link to the Gmail setup help page;
- link to account management.

The stored secret is never assigned to the LiveView or rendered as a value. A
mask may appear only as explanatory text or placeholder. The form submits once;
it does not use `phx-change` for secret keystrokes. After validation or persistence
failure, the submitted secret is cleared rather than echoed.

Changing or removing configuration warns that Gmail receive/send stops and
connected accounts require reconnection.

## Provider Help Pages

Use `/settings/oauth/:provider/help`, resolved only through the code-defined
catalog. Each help page supplies:

- provider-specific setup checklist;
- exact copyable callback URI;
- required scopes with a short purpose explanation;
- testing and production notes;
- official provider documentation links;
- back link to that provider's configuration card.

The Gmail page covers:

1. Create or select a Google Cloud project.
2. Enable the Gmail API.
3. Configure OAuth branding and audience.
4. Add only `openid`, `email`, `gmail.readonly`, and `gmail.send`.
5. Add test users while the app is in Testing mode.
6. Create a Web application OAuth client.
7. Register the exact callback URI displayed by Manifold.
8. Copy the client ID and secret into Settings → OAuth.
9. Understand Google verification requirements before public use.

The page notes that Testing-mode authorizations can expire after seven days and
that sensitive or restricted scopes may require Google verification. It links to
official Google documentation rather than copying volatile Cloud Console screen
labels or screenshots.

Initial official references:

- https://support.google.com/cloud/answer/15549945?hl=en
- https://support.google.com/cloud/answer/13463073?hl=en
- https://support.google.com/cloud/answer/13807380?hl=en

## Runtime Configuration Changes

Remove the Gmail client ID and secret loader from `config/runtime.exs`. Remove
`MANIFOLD_GMAIL_CLIENT_ID` and `MANIFOLD_GMAIL_CLIENT_SECRET` from tests,
operator documentation, and supported-environment lists.

Code-defined Google endpoint defaults remain static application configuration.
Endpoint override environment variables are outside the browser credential form
and remain an operator/development concern unless separately removed.

Microsoft runtime configuration remains unchanged in this feature. It is not
listed as a configurable OAuth module until it is migrated to the catalog.

## Error Handling and Secret Safety

- Missing row: provider is not configured.
- Invalid form: return field errors; clear the secret value.
- Encryption failure: roll back without persistence.
- Decryption failure: fail closed as configuration error.
- Concurrent update: return a stale-settings error and reload the current view.
- Configuration changed during OAuth: reject the transaction and start over.
- Database failure: return a generic temporary settings error.

Secrets and ciphertext must never appear in HTML, socket assigns retained after
the event, changeset inspection, logs, telemetry, flash messages, activity events,
or error details.

## Security Boundary

The Settings routes currently rely on the application's trusted-local-instance
model and do not authenticate an administrator. This feature does not claim the
OAuth page is administrator-only. Network-exposed deployments must add access
control as a separate feature before treating browser-managed secrets as safe.

## Migration and Rollout

The migration creates the provider-settings table and adds a provider-setting
version field to OAuth transactions. It does not read process environment or
backfill credentials.

This is a non-rolling configuration cutover. Before migration, drain old Phoenix,
connector, and Oban workers so old nodes cannot continue using environment-backed
Google credentials while new nodes use database settings. After deployment,
Gmail remains unavailable until the operator saves Google credentials in
Settings → OAuth and reconnects existing Gmail accounts.

Rollback must refuse if provider settings or transactions using the new version
fence cannot be represented by the old schema without losing active configuration.

## Testing

### Persistence and crypto

- Creation requires both client ID and secret.
- Raw rows never contain plaintext secret material.
- Correct AAD decrypts; wrong AAD and corrupt ciphertext fail closed.
- Blank-secret retention preserves ciphertext when the client ID is unchanged.
- Client ID changes require a new secret.
- Secret rotation replaces ciphertext.
- Removal deletes only the selected provider setting.

### Lifecycle and concurrency

- Initial save with legacy Gmail grants requires reconnect.
- Client ID change, secret rotation, and removal mark only Gmail dependencies
  `reconnect_required` and disable them.
- Other provider settings and methods are unchanged.
- Unfinished Gmail OAuth transactions are invalidated.
- Version mismatch rejects an in-flight OAuth callback.
- Concurrent saves cannot overwrite a newer setting silently.

### Resolver integration

- Old Google credential environment variables are ignored even when present.
- Configured-provider discovery changes immediately after save/remove.
- OAuth start uses the database client ID.
- Code exchange and refresh use the database secret.
- Receive sync and Gmail send resolve the same setting.
- Missing/corrupt settings make all Gmail paths unavailable consistently.

### Web

- OAuth nav route renders and marks the correct section current.
- Catalog renders Gmail as the first supported provider.
- Save, blank-secret keep, replacement, and confirmed removal work.
- Stored and submitted secrets are absent from rendered HTML after every event.
- Callback URI is exact and copyable.
- Gmail help page renders the required scopes, checklist, callback, and official
  links.
- Unsupported provider help routes return a safe not-found response.

### Regression

- Existing Gmail receive/send, uncertainty, and account-isolation suites pass.
- Microsoft configuration behavior remains unchanged.
- Format, strict compile, scoped application suites, and migration up/down checks
  pass.

## Documentation

Update:

- `README.md` and `docs/DESIGN.md` for Settings-managed Google credentials;
- operational cutover and reconnect instructions;
- Gmail receive/send feature references;
- a new `.agents/skills/develop/references/oauth-provider-settings.md` covering
  ownership, catalog extension, secret invariants, and focused test commands.

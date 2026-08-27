# Microsoft OAuth Provider Settings Design

**Date:** 2026-08-27

**Status:** Approved design

**Scope:** Move Microsoft 365 OAuth application credentials from environment
variables into the existing Settings-managed OAuth provider store

## Summary

Manifold will configure Microsoft 365 OAuth application credentials at
`/settings/oauth`, using the same encrypted database-backed workflow as Google.
The page will render Google OAuth first and Microsoft OAuth second. Saving,
rotating, or removing Microsoft credentials takes effect immediately without an
application restart.

`MANIFOLD_MICROSOFT_CLIENT_ID` and `MANIFOLD_MICROSOFT_CLIENT_SECRET` will no
longer be read, imported, or used as fallback configuration. Microsoft remains
limited to work/school accounts through the fixed `organizations` tenant.

## Goals

- Add Microsoft OAuth to the code-defined provider catalog and Settings page.
- Reuse the existing encrypted provider-settings persistence and generic UI.
- Resolve Microsoft client credentials from PostgreSQL for every OAuth, receive,
  refresh, and send operation.
- Apply the same provider-setting generation fence used by Google to Microsoft.
- Enable Microsoft receive and send choices immediately after a successful save.
- Remove Microsoft client-credential environment configuration completely.
- Preserve the existing Microsoft Graph receive/send transport and
  least-privilege scope boundaries.

## Non-goals

- Personal Outlook.com accounts or the `common` and `consumers` tenants.
- A configurable tenant field, endpoint field, scope editor, or arbitrary OAuth
  provider definition in the browser.
- Importing legacy environment credentials into PostgreSQL.
- Environment fallback or precedence rules.
- Remote grant revocation when local configuration is removed.
- Administrator authentication for Settings; the existing trusted-local-instance
  boundary remains unchanged.
- A new credential table or schema migration.

## Chosen Approach

Use a database-only hard cutover. Microsoft joins the same provider catalog,
provider-settings store, resolver, generation fencing, lifecycle transitions,
Settings cards, and help flow as Google.

Alternatives rejected:

- A one-time environment import adds secret-handling machinery and cannot prove
  that existing refresh tokens belong to the imported application.
- A database-first environment fallback preserves restart-dependent behavior,
  permits unfenced legacy OAuth transactions, and contradicts the requested
  configuration model.

## Provider Catalog

Add `Manifold.Connectors.OAuthProvider.Microsoft` and register it after Gmail in
`Manifold.Connectors.OAuthProviderCatalog`.

The trusted definition supplies:

- key `microsoft`;
- display name `Microsoft 365` and Microsoft icon;
- callback path `/connectors/microsoft/callback`;
- receive and send capabilities;
- delegated `User.Read`, `Mail.Read`, and `Mail.Send` scopes plus the identity
  and durable refresh scopes already required by the connector;
- fixed `organizations` authorization and token endpoints;
- the Microsoft Graph v1 API base URL;
- provider-specific help content and official Microsoft documentation links.

Users can store only the client ID and client secret. They cannot alter tenant,
endpoints, capabilities, callbacks, or scopes in the browser.

## Persistence and Secret Handling

Reuse `connector_oauth_provider_settings` and
`Manifold.Connectors.ProviderSettings` unchanged. The table is already
provider-neutral and stores one unique provider row with a plaintext client ID,
an AES-256-GCM encrypted client secret, key version, optimistic lock version,
and timestamps.

Microsoft uses the existing associated-data contract:

```text
oauth_provider_setting:<setting-id>:client_secret
```

`MANIFOLD_CONNECTOR_ENCRYPTION_KEY` remains the stable out-of-database master
key. Neither the plaintext secret nor ciphertext may enter browser HTML,
retained LiveView assigns, logs, telemetry, activity metadata, job arguments,
flash messages, or public errors.

No migration is required. Provider catalog membership activates the existing
validation and lifecycle behavior for Microsoft.

## Provider Resolution

Generalize `Manifold.Connectors.ProviderConfig` so Gmail and Microsoft both:

1. load the current provider-setting row;
2. decrypt the client secret;
3. combine the credentials with trusted non-secret catalog configuration; and
4. return the setting UUID and lock version with the resolved configuration.

There is no credential cache. Every configured-provider check, OAuth start,
authorization-code exchange, token refresh, receive sync, send-method checkout,
and Microsoft submission resolves current database state.

Microsoft's Graph adapter continues receiving only the access token and the
allowlisted Graph base URL or test transport option. Client credentials remain
inside the connector OAuth boundary.

## OAuth Generation Fence

Microsoft OAuth transactions snapshot the provider-setting UUID and
`lock_version` at authorization start. Callback processing validates that
generation before external code exchange and validates it again under the
provider advisory lock before persisting credentials or methods.

Saving, rotating, removing, or removing and recreating the Microsoft setting
while consent is in flight causes `provider_configuration_changed`; the user
must begin a new OAuth attempt. Legacy Microsoft transactions with nil setting
generation are deleted and rejected after cutover.

External Microsoft calls must not run while holding the database transaction or
provider advisory lock.

## Settings UI and Help

`/settings/oauth` renders two catalog-driven cards in stable order:

1. Google OAuth
2. Microsoft OAuth

The Microsoft card reuses the existing generic form and contains:

- **Configured**, **Not configured**, or **Configuration error** status;
- exact read-only callback URI;
- client ID text input;
- empty password-only client secret input;
- blank-secret preservation when the client ID is unchanged;
- **Save changes**, **Setup help**, **Manage accounts**, and confirmed
  **Remove configuration** actions.

The Microsoft help page covers:

- creating a Microsoft Entra Web application;
- registering the exact callback shown by Manifold;
- restricting the registration to work/school accounts;
- creating and safely copying a client secret;
- delegated `User.Read`, `Mail.Read`, and `Mail.Send` permissions;
- `offline_access` for durable refresh;
- tenant user-consent and administrator-consent policies;
- the explicit exclusion of personal Outlook.com accounts and
  `Mail.ReadWrite`.

Saving a valid Microsoft setting enables the receive and send picker cards on
their next mount without restarting Phoenix or workers.

## Save, Rotation, Removal, and Lifecycle

The generic provider-scoped transaction behavior applies to Microsoft:

- Initial save requires both client ID and client secret.
- A blank secret preserves current ciphertext only when the client ID is
  unchanged.
- Changing the client ID requires a new secret.
- Supplying a new secret rotates it.
- Removal is a separately confirmed action and deletes only the provider-setting
  row.

Every actual initial save, client-ID change, secret rotation, or removal marks
existing Microsoft authorizations and receive/send methods
`reconnect_required`, disables those methods, and invalidates unfinished
Microsoft OAuth transactions. Other providers remain unchanged.

Existing encrypted Microsoft user grants remain stored locally. Manifold does
not remotely revoke the grant or assume that newly entered application
credentials own existing refresh tokens.

## Runtime Configuration Cutover

Remove all runtime reads and supported-configuration documentation for:

```text
MANIFOLD_MICROSOFT_CLIENT_ID
MANIFOLD_MICROSOFT_CLIENT_SECRET
```

Retain these non-credential settings as trusted operator configuration:

```text
MANIFOLD_CONNECTOR_ENCRYPTION_KEY
MANIFOLD_MICROSOFT_AUTHORIZATION_URL
MANIFOLD_MICROSOFT_TOKEN_URL
MANIFOLD_MICROSOFT_API_BASE_URL
```

The tenant remains fixed to `organizations`; no Settings field is added for it.
The old credential names remain only in regression tests proving that complete
and partial legacy values are ignored and never copied into application config
or PostgreSQL.

This is a non-rolling cutover. Operators must drain old Phoenix, connector, and
Oban processes before deploying the new resolver. After deployment Microsoft is
unavailable until credentials are saved in Settings and existing Microsoft
accounts are reconnected. Queued Microsoft sends should be drained before the
cutover to avoid preventable checkout failures.

## Error Handling

- Missing setting: `provider_not_configured` and disabled receive/send choices.
- Invalid form: provider-scoped field errors with the submitted secret cleared.
- Undecryptable setting: secret-safe `provider_configuration_error`.
- Stale form lock: `stale_oauth_provider_setting` and authoritative reload.
- Changed OAuth generation: `provider_configuration_changed` and restart OAuth.
- Database failure: generic temporary settings or provider configuration error,
  without environment fallback.
- Unsupported provider or help route: safe rejection without creating atoms or
  exposing catalog internals.

## Testing

### Catalog and Settings

- Catalog order is exactly Gmail then Microsoft.
- Microsoft definition contains the fixed callback, capabilities, scopes,
  endpoints, tenant, help content, and official links.
- `/settings/oauth` renders both cards with provider-keyed IDs.
- Microsoft save stores an encrypted secret and enables receive/send discovery
  immediately.
- Blank-secret retention, client-ID change, secret rotation, confirmed removal,
  stale versions, and provider isolation behave as designed.
- Microsoft help renders the exact callback, required scopes, consent notes,
  work/school limitation, and accessible navigation.

### Resolver and OAuth

- Complete and partial legacy Microsoft credential environment variables are
  ignored.
- Missing, corrupt, and database-unavailable settings fail closed.
- OAuth start, code exchange, token refresh, receive sync, and send checkout use
  the same stored setting.
- Microsoft transactions contain non-nil setting UUID/version snapshots.
- Rotation, removal, and remove/recreate races fail before exchange or before
  final persistence as applicable.
- Nil-generation legacy Microsoft transactions are rejected after cutover.

### Lifecycle and Regression

- Microsoft setting mutations affect only Microsoft authorizations and methods.
- Existing Microsoft Graph receive, folder mapping, send, retry uncertainty,
  purge, and account-isolation suites remain green.
- Google Settings-managed OAuth behavior remains unchanged.
- Scoped Data, Connectors, Web, Outbound, Mail, and Account Lifecycle tests pass.
- `mix format --check-formatted` and
  `mix compile --warnings-as-errors` pass.
- Browser smoke verification proves that saving Microsoft credentials enables
  both method pickers without restart and that secrets never render.

## Documentation

Update `README.md`, `docs/DESIGN.md`, applicable milestone and historical design
notes, and the OAuth-provider, Gmail, and Microsoft feature references. Remove
operator guidance that treats Microsoft client credentials as environment
configuration and document the non-rolling Settings cutover and reconnect steps.

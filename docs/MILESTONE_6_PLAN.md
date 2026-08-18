# Manifold Milestone 6 Implementation Plan

**Status:** Implemented

**Current-state note:** This document records the original receive-focused
Milestone 6 scope. Later work implemented account-selected Gmail API and Microsoft
Graph send plus IMAP and EAS receive methods. Provider receive synchronization
remains read-only with respect to remote Gmail and Microsoft mailboxes.

## Implementation Status

- [x] Add the `manifold_connectors` application and dependency boundary.
- [x] Add centralized connector and external-ingress migrations.
- [x] Implement one-time OAuth state, PKCE `S256`, and encrypted secret
      envelopes.
- [x] Implement Gmail receive-only profile, list/history, and raw fetch adapters.
- [x] Implement Microsoft Graph profile, folder/message delta, immutable ID, and
      raw fetch adapters.
- [x] Import provider raw bytes through the durable spool and atomic Ingest
      boundary without synthesizing SMTP metadata.
- [x] Persist account, credential, cursor, remote-message, and connector-event
      state.
- [x] Add bounded sync and remote-state Oban workers with idempotent local
      effects.
- [x] Wire production runtime configuration and fail-fast encryption-key
      validation.
- [x] Add `manifold_connectors` to the local release and enable the
      `connectors` Oban queue.
- [x] Add OAuth controllers and the no-auth `/settings/accounts` LiveView.
- [x] Move Google client credentials into encrypted, database-backed
      `/settings/oauth` configuration with provider-specific setup help.
- [x] Add periodic polling and missing-job reconciliation.
- [x] Normalize provider raw-fetch disappearance into a deletion reconciliation
      path.
- [x] Complete end-to-end Graph move-order and connector crash-boundary tests.
- [x] Prove fresh migration, full test, production assets, release, process, and
      responsive browser checks.

## Scope

Milestone 6 adds read-only external mailbox synchronization for Gmail and
Microsoft 365:

1. Connect a provider account to one existing local Manifold mailbox through
   OAuth 2.0 authorization code flow with PKCE.
2. Encrypt provider access and refresh tokens at rest.
3. Import exact provider-supplied RFC message bytes through Manifold's existing
   durable spool and ingest pipeline.
4. Perform resumable initial synchronization and cursor-based incremental
   synchronization through Oban.
5. Preserve provider message identity, folder or label state, tombstones, sync
   cursors, and operational events.
6. Apply supported remote folder, read, and starred state to the local mailbox
   projection without deleting the immutable raw source.
7. Expose connection, synchronization, reconnect, and disconnect operations in
   the no-auth local Phoenix interface.

The original milestone did not request remote mutation or send scopes,
synchronize contacts or calendars, implement provider push notifications, expose
provider tokens, implement direct outbound MX delivery, or add IMAP, POP3, or
JMAP. The future-send and IMAP statements are superseded: Gmail API, Microsoft
Graph, and SMTP send are implemented as account-selected outbound methods, and
read-only IMAP plus EAS receive are implemented. POP3, JMAP, provider push, and
direct outbound MX delivery remain out of scope.

## Application Boundary

Add:

```text
manifold_connectors
  -> manifold_core
   + manifold_data
   + manifold_accounts
   + manifold_ingest
   + manifold_mail

manifold_web
  -> public APIs from manifold_connectors
```

`manifold_connectors` owns external-account credentials, OAuth transactions,
provider adapters, synchronization cursors, provider-message identities,
connector events, and Oban jobs. It references local mailboxes and inbound
deliveries by ID and does not use account, ingest, or mail private schemas.

`manifold_ingest` adds a transport-neutral, idempotent external-source
acceptance API. It owns the atomic relationship between a trusted external
message identity and a local inbound delivery. Provider adapters do not write
spool, ingest, mail, or Oban tables directly.

## Persistent Model

`ExternalAccount` stores:

- Active local mailbox ID, provider, immutable provider account ID, and provider
  email. A known provider identity cannot be reassigned to another mailbox.
- Connection and synchronization state.
- Granted scopes.
- Last attempt, last success, and sanitized classified error.
- Optimistic lock version and disconnect timestamp.

`Credential` separately stores versioned AES-256-GCM encrypted access and
refresh tokens plus token expiry. `OAuthProviderSetting` stores the code-defined
provider key, plaintext client ID, encrypted client secret, key version, and lock
version. `OAuthTransaction` stores a hashed one-time state, provider, mailbox ID,
encrypted PKCE verifier, exact redirect URI, expiry, consumed timestamp, and the
provider-setting UUID/version snapshot used to start Gmail authorization.

`SyncCursor` stores one serialized synchronization lane per provider scope:

- Gmail uses one mailbox-wide history lane.
- Microsoft Graph uses a folder-discovery lane and one message-delta lane per
  provider folder.
- Bootstrap anchor, opaque page cursor, committed delta cursor, phase, and
  last completed time.

`RemoteMessage` stores a provider message ID, provider thread ID, local
inbound delivery ID, provider timestamp, normalized remote state, current
folder and labels, and tombstone state. The unique identity is
`external_account_id + provider_message_id`.

`ConnectorEvent` is append-only operational history. Metadata is bounded and
must not contain tokens, authorization codes, raw message bytes, provider
request bodies, or opaque cursor values.

`ExternalIngressIdentity`, owned by `manifold_ingest`, maps
`provider + source_id + external_message_id` to one inbound delivery and
retains the accepted raw and target-mailbox fingerprints. Repeated matching imports
return the original receipt; conflicting content is rejected.

## Original OAuth Contract

The bullets below record the receive-only Milestone 6 contract. Later send work
keeps receive least-privilege but incrementally adds `gmail.send` for Gmail and
`Mail.Send` for Microsoft to each provider's shared authorization.

- Providers are selected from the fixed `gmail` and `microsoft` allowlist.
- State contains at least 256 random bits, is stored only as a SHA-256 digest,
  expires quickly, and is consumed once under a database row lock.
- PKCE always uses `S256`.
- Redirect URIs are generated from the configured Phoenix Endpoint URL and must
  match the stored transaction exactly.
- Gmail requests `openid email` and `gmail.readonly` with offline access.
- Gmail account identity uses the OpenID UserInfo `sub`; the email address is
  display metadata and is not used as the durable account identity.
- Microsoft requests `openid profile offline_access User.Read Mail.Read`.
- Returned scopes are validated before an account becomes active.
- A token response that omits a refresh token never erases a retained refresh
  token.
- Refresh-token rotation is committed under an optimistic account lock.
- `invalid_grant`, revoked consent, and insufficient scope move the account to
  `reconnect_required`; transient HTTP failures remain retryable.
- Production requires a base64-encoded 32-byte connector encryption key.

## Runtime Configuration

The production local release maps these environment variables into
`:manifold_connectors`:

```text
MANIFOLD_CONNECTOR_ENCRYPTION_KEY
MANIFOLD_GMAIL_AUTHORIZATION_URL
MANIFOLD_GMAIL_TOKEN_URL
MANIFOLD_GMAIL_USERINFO_URL
MANIFOLD_GMAIL_API_BASE_URL
MANIFOLD_MICROSOFT_CLIENT_ID
MANIFOLD_MICROSOFT_CLIENT_SECRET
MANIFOLD_MICROSOFT_TENANT
MANIFOLD_MICROSOFT_AUTHORIZATION_URL
MANIFOLD_MICROSOFT_TOKEN_URL
MANIFOLD_MICROSOFT_API_BASE_URL
```

The provider-console callback contracts are:

```text
https://<PHX_HOST>/connectors/gmail/callback
https://<PHX_HOST>/connectors/microsoft/callback
```

Development uses the same paths at `http://localhost:4290`. The routes are not
registered with provider consoles automatically. Microsoft defaults to the
`organizations` tenant and Graph API `https://graph.microsoft.com/v1.0`.
Endpoint overrides must be absolute HTTPS URLs without credentials or
fragments.

Google client credentials are configured at `/settings/oauth`, with instructions
and the deployed exact callback at `/settings/oauth/gmail/help`. The client ID is
stored plaintext and the secret is encrypted with
`oauth_provider_setting:<setting-id>:client_secret` associated data. A blank
secret preserves the stored secret only when the client ID is unchanged; changing
the client ID requires a new secret. The legacy `MANIFOLD_GMAIL_CLIENT_ID` and
`MANIFOLD_GMAIL_CLIENT_SECRET` variables are ignored and are not imported or used
as fallback. Endpoint overrides remain static operator configuration. Microsoft
environment behavior is unchanged.

Development has a non-production encryption key but no default OAuth client
credentials. Production requires a stable `MANIFOLD_CONNECTOR_ENCRYPTION_KEY` as
the out-of-database master key. Missing Gmail settings fail closed as
`provider_not_configured`; corrupt settings use `provider_configuration_error`.
Browser output, logs, telemetry, and activity events never include secrets or
ciphertext. The Settings routes retain the trusted-local-instance boundary and
do not add administrator authentication.

The database-backed provider catalog is code-defined rather than user-extensible.
`Manifold.Connectors.OAuthProviderCatalog` and
`Manifold.Connectors.OAuthProvider.<Provider>` own the stable key, name, icon,
callback, capabilities, scopes, endpoints, and help content. Users cannot enter
arbitrary endpoints or scopes. A future provider reuses the generic settings
table without provider-specific columns, but a usable connector may still need a
migration for existing OAuth/provider-kind database constraints as well as its
OAuth, refresh, receive, send, and lifecycle integration.

### Provider-settings cutover

`20260818000100_add_oauth_provider_settings.exs` is non-rolling. Drain old
Phoenix, connector, and Oban processes before migration. There is no environment
backfill, Gmail remains unavailable until Settings → OAuth is saved, and existing
Gmail grants require reconnect. Saving, rotating, or removing settings takes
effect without restart and never auto-resumes disabled methods; removal does not
revoke Google access.

OAuth start snapshots the setting UUID and lock version. Completion revalidates
that generation before provider exchange and, under the provider advisory lock,
again in the final database transaction after external I/O; no database lock is
held across the network request. Rollback refuses while a provider setting or a
fenced OAuth transaction exists.

Staging must confirm immediate receive/send picker enablement after save, the help
page and exact callback, real receive and send, reconnect after client-ID/secret
rotation, removal behavior, and no automatic method resumption.

## Synchronization Flow

### Gmail

1. Read the profile and freeze its email address and bootstrap `historyId`.
2. List messages with spam and trash included.
3. Fetch each new message with `format=RAW`, base64url-decode it, and durably
   import the exact bytes.
4. Preserve current label IDs and normalize Inbox, Archive, Trash, read, and
   starred state. Sent and Draft labels remain provider metadata and map to the
   local Archive lane because this milestone does not synchronize provider
   draft or sent-mail workflows.
5. After the initial scan, replay history from the frozen bootstrap cursor.
6. Follow every history page and commit the final `historyId` only after all
   covered imports and tombstones are durable.
7. A stale history cursor restarts a non-destructive full reconciliation.

### Microsoft 365

1. Read `/me` and require a stable account ID and mail address.
2. Discover mail folders through folder delta.
3. Synchronize each folder through its own message delta lane.
4. Send `Prefer: IdType="ImmutableId"` on every message operation.
5. Treat `nextLink` and `deltaLink` as opaque HTTPS URLs and validate their
   authority before following them.
6. Fetch new raw messages through `/$value`; never synthesize MIME from Graph
   JSON.
7. Treat a removal as a folder-membership tombstone first. A matching immutable
   ID observed in another folder is a move, not deletion.
8. An expired delta cursor starts a non-destructive replacement delta round.

Each synchronization job processes a bounded page. Provider page effects are
idempotent, and the current Oban job snoozes when another page or lane remains.
The cursor checkpoint is durable before that worker continues. A five-minute
Oban cron job recreates missing sync work for eligible accounts. `429` honors a
numeric `Retry-After`; transient transport and `5xx` failures snooze the current
Oban job. Provider `404` during raw fetch is normalized into an idempotent
remote tombstone before the page cursor advances.

## Durable Import

For each previously unseen provider message:

1. Fetch bounded raw bytes from the provider.
2. Construct a trusted provider-import descriptor for the configured local
   mailbox and storage domain. Do not fabricate SMTP peer, HELO, envelope, or
   recipient facts.
3. Write a version-2 private spool bundle with an explicit source kind and
   atomically rename it to `ready`.
4. Call `Manifold.Ingest.import_external/3` with provider account and message
   identity.
5. Commit the inbound delivery, target mailbox entry, accepted event, archival
   job, and external-ingress identity in one transaction. A provider import
   creates no `DeliveryRecipient` because no SMTP envelope recipient was
   observed.
6. Upsert the connector message mapping from the returned durable receipt.
7. Apply remote mailbox state only through the public `Manifold.Mail` API after
   the normal projection exists.

The connector cursor never advances past a provider page until every actionable
message represented by that page has reached its required durable local state.
For a Microsoft folder-membership tombstone, the connector probes the global
message resource: a surviving message is a non-destructive folder move, while a
`404` records a remote deletion without deleting local immutable data.

## User Interface

The `/settings/accounts` settings landing page shows:

- Provider account and destination local mailbox.
- Connected, syncing, reconnect-required, failed, and disconnected states.
- Last successful synchronization and sanitized error.
- Connect, sync-now, and disconnect commands.

OAuth initiation and callback use ordinary Phoenix controllers. LiveView only
persists commands or enqueues Oban work; it never calls provider APIs. Tokens,
authorization codes, raw paths, object keys, cursor values, and provider
response bodies are not assigned to a socket or rendered.

## Crash Boundaries

The implementation exposes fault boundaries for the core acceptance and sync
transactions, with deterministic coverage for replay, cursor expiry, failure,
deletion, and move ordering:

1. OAuth state creation before provider redirect.
2. Callback replay and expired or mismatched state.
3. Token exchange success before local account commit.
4. Refresh-token rotation before sync-page completion.
5. Raw fetch interruption before ready spool rename.
6. Ready spool rename before external acceptance commit.
7. External acceptance commit before connector-message mapping.
8. Connector-message mapping before cursor checkpoint.
9. Cursor checkpoint before continuation-job execution.
10. Gmail history expiry during incremental synchronization.
11. Graph delta expiry and move events observed in opposite folder order.
12. Provider message deletion between listing and raw fetch.
13. Repeated page, message, tombstone, and state application.
14. Archived raw and local message retention after provider deletion.
15. Disconnect while synchronization work is queued or executing.

The central invariant is that a committed provider cursor never names mail that
has not first crossed Manifold's durable local acceptance boundary.

## Verification

- [x] Fresh migration from an empty local PostgreSQL database.
- [x] Pure OAuth state, PKCE, token-envelope, error-classification, and cursor
      URL tests pass in the final Milestone 6 tree.
- [x] Gmail and Microsoft adapter tests pass against local deterministic HTTP
      fakes.
- [x] Initial, incremental, cursor-expiry, retry, deletion, move, and
      crash-boundary tests pass without live Internet services.
- [x] Web tests cover no-auth account management and secret non-disclosure.
- [x] Full format, warnings-as-errors compile, test, production assets, release,
      migration, process smoke, and responsive browser checks pass.

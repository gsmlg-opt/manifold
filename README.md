# Manifold

Manifold is a self-hosted Phoenix webmail application backed by an Elixir-native
mail platform. The main runtime acts as a mail client for provider-hosted
accounts; the optional `manifold_edge` release provides durable inbound SMTP for
installations that deploy it.

## Milestones 0-6

Milestones 0-6 implement durable inbound delivery, mailbox projection, managed
outbound submission, fail-closed inbound policy, optional cloud ingress,
read-only Gmail and Microsoft 365 synchronization, and account-selected Gmail,
Microsoft Graph, or SMTP submission:

- Phoenix umbrella with explicit Core, Data, Accounts, Storage, Ingest, SMTP,
  Mail, Security, Outbound, Cloud, Edge, Connectors, and Web application
  boundaries.
- Optional `manifold_edge` release and local `manifold_cloud` pull client.
- PostgreSQL/Ecto migrations and Oban jobs.
- Domain, mailbox, alias, alias target, and recipient resolution.
- Edge-only `gen_smtp` listener, using port `2525` in development and port `25`
  in the edge release by default.
- Durable spool bundles under `tmp/`, `ready/`, `failed/`, and `quarantine/`.
- Local filesystem raw-message store.
- Bounded asynchronous MIME projection with ordered headers, addresses, selected
  text/HTML bodies, attachments, mailbox folders, reference-based threading, and
  bounded PostgreSQL full-text search.
- Content-addressed local attachment storage.
- Responsive Phoenix LiveView inbox, folder, search, conversation, and mailbox
  state workflows.
- Persistent plain-text drafts with compose, reply, reply-all, and forward
  workflows.
- Atomic outbound queueing with Oban, immutable provider MIME and frozen account
  send-method snapshots, Gmail API, Microsoft Graph, authenticated SMTP
  submission, and legacy Resend compatibility.
- Authenticated Resend webhook ingestion with per-recipient delivered, bounced,
  complained, suppressed, delayed, and failed state.
- Sent-mail and provider lifecycle views that distinguish provider acceptance
  from final recipient delivery.
- Versioned SPF, DKIM, DMARC, malware, and spam assessment results through
  replaceable adapters. Disabled adapters persist `not_evaluated`; they never
  fabricate a successful result.
- Fail-closed mailbox quarantine from SMTP acceptance until policy commits, with
  audited manual release and retry-safe security jobs.
- Per-peer SMTP connection concurrency, connection rate, and transaction rate
  controls.
- Isolated sanitized HTML rendering and mailbox-scoped attachment downloads.
- Operational LiveViews for domains, mailboxes, aliases, inbound deliveries, and
  delivery detail.
- Versioned recipient-route snapshots, edge SMTP recipient rejection, signed
  local-pull synchronization, streamed raw import, idempotent provenance, and
  acknowledge-before-cleanup recovery.
- Read-only Gmail and Microsoft Graph provider adapters, encrypted OAuth
  transactions and credentials, durable provider-message identity, bounded
  cursor pages, and idempotent raw-message import through the normal spool and
  ingest boundary.
- Trusted-local OAuth provider settings at `/settings/oauth`, with encrypted
  database-backed Google and Microsoft client secrets and catalog-defined setup
  help.

## Out Of Scope

The current milestones intentionally do not implement rich-text composition,
outbound attachments, bundled DNS authentication engines, bundled spam or
malware engines, POP3, JMAP, provider push notifications, Gmail or Microsoft
mailbox mutation, Graph draft creation, or cloud provider hosting.
Read-only IMAP and Exchange ActiveSync (EAS) Inbox import are supported via the
connectors application; POP3 and JMAP remain out of scope. Production
authentication and scanning engines
plug into the Milestone 4 adapter boundaries. The optional edge is ingress-only
and never performs outbound MX delivery.

Manifold never performs direct outbound Internet MX delivery. Outbound messages
use the sending account's frozen Gmail API, Microsoft Graph, or authenticated
SMTP method. Legacy Resend submissions remain supported for messages queued
with that provider shape. Microsoft receive remains read-only; independently
authorized send uses direct MIME Graph `sendMail`.

## External Mailbox Connectors

Milestone 6 imports provider-hosted mail into an existing local Manifold
mailbox. It does not make Gmail or Microsoft 365 the metadata source of truth
for Manifold and does not bypass the durable local acceptance pipeline.

The current implementation includes:

- Purpose-scoped OAuth authorization-code primitives with one-time, hashed state
  and PKCE `S256`; Gmail and Microsoft receive/send grants incrementally share
  one provider-specific authorization record.
- AES-256-GCM encryption envelopes with context-bound associated data. Shared
  Gmail and Microsoft tokens bind the authorization ID plus access/refresh kind;
  PKCE verifiers bind the provider plus account ID.
- Gmail OpenID identity, message-list, history, and `format=RAW` operations
  using the stable subject identifier and `gmail.readonly` scope. The shared
  authorization can also hold `gmail.send` for outbound Gmail API submission.
- Microsoft Graph profile, folder-delta, message-delta, immutable message ID,
  and `/$value` raw-message operations using `Mail.Read`, plus independently
  scoped direct MIME `sendMail` using `Mail.Send`.
- Transactional account, credential, cursor, event, and first Oban sync-job
  persistence after OAuth completion.
- Bounded, retryable sync pages with provider-message identity and cursor
  checkpointing only after every message in the page has crossed the local
  acceptance boundary.
- Idempotent external import through a version-2 spool bundle, raw archive,
  mailbox projection, and a retryable remote-state application job.
- A no-auth `/settings/accounts` LiveView with OAuth start/callback routes,
  sync-now, status, and disconnect controls.
- A trusted-local `/settings/oauth` LiveView for Google and Microsoft client
  credentials, with `/settings/oauth/gmail/help` and
  `/settings/oauth/microsoft/help` for exact callbacks, scopes, and setup steps.
- A local-release `connectors` Oban queue and five-minute polling job that
  recreates missing active-account sync work.

Provider imports are transport-neutral. They set `source_kind` to
`provider_import` and retain provider account/message identity, but they do not
invent an SMTP peer IP, HELO, envelope sender, or `RCPT TO` recipient. No
`DeliveryRecipient` row is created when no SMTP transaction occurred.

There are no Gmail watch notifications or Microsoft Graph subscriptions yet.
Sync is pull-based. OAuth completion inserts the first sync job
transactionally; the local release polls connected, syncing, and failed
accounts every five minutes and inserts any missing active sync job. The
settings view can also enqueue an individual sync.

A provider message that disappears between listing and raw fetch is normalized
into an idempotent remote tombstone. The local raw object and accepted delivery
remain immutable when a provider later deletes its copy.

Each provider account identity is permanently bound to the local Manifold account
chosen at first connection. Reauthorization refreshes that account but cannot
silently move it to a different account. Gmail additionally requires the exact
connected canonical address to match the Manifold account address.

### Provider Configuration

The local release and development runtime support:

```text
MANIFOLD_CONNECTOR_ENCRYPTION_KEY
MANIFOLD_GMAIL_AUTHORIZATION_URL
MANIFOLD_GMAIL_TOKEN_URL
MANIFOLD_GMAIL_USERINFO_URL
MANIFOLD_GMAIL_API_BASE_URL
MANIFOLD_MICROSOFT_AUTHORIZATION_URL
MANIFOLD_MICROSOFT_TOKEN_URL
MANIFOLD_MICROSOFT_API_BASE_URL
```

`MANIFOLD_CONNECTOR_ENCRYPTION_KEY` must be standard Base64 encoding of exactly
32 random bytes and is required for the production local release even when no
provider client is configured. It remains the out-of-database master key for
provider-setting, OAuth-token, and PKCE ciphertext. Generate one with:

```sh
openssl rand -base64 32
```

Configure Google and Microsoft client IDs and secrets in **Settings → OAuth** at
`/settings/oauth`; provider-specific instructions are at
`/settings/oauth/gmail/help` and `/settings/oauth/microsoft/help`. A client ID is
stored as plaintext because it is sent in browser authorization requests. Each
client secret is encrypted in PostgreSQL and is never returned to the browser.
On an existing configuration, leaving the secret field blank preserves it when
the client ID is unchanged. Changing the client ID requires a new secret.
Changing either credential or removing a configuration immediately disables
that provider's affected receive/send methods and requires reconnect. Removal is
local only and does not revoke the grant at Google or Microsoft.

Legacy Google and Microsoft client-credential environment variables are ignored
and are never imported or used as a fallback. Provider endpoint override
variables remain static operator/development configuration. For Microsoft, only
the authorization URL, token URL, and Graph base URL overrides are retained. No
application restart is required after either provider's credential save,
rotation, or removal.

The provider application registrations use these exact callback paths:

```text
https://<your-manifold-host>/connectors/gmail/callback
https://<your-manifold-host>/connectors/microsoft/callback
```

For local development, the intended callbacks are:

```text
http://localhost:4290/connectors/gmail/callback
http://localhost:4290/connectors/microsoft/callback
```

Register only the production HTTPS callbacks with provider consoles. Local HTTP
callbacks are suitable for provider development registrations where the
provider permits loopback HTTP. OAuth transactions compare the callback URI
byte-for-byte with the URI stored at authorization start.

The provider configuration uses:

```text
Gmail authorization: https://accounts.google.com/o/oauth2/v2/auth
Gmail token:         https://oauth2.googleapis.com/token
Gmail API:           https://gmail.googleapis.com

Microsoft authorization:
  https://login.microsoftonline.com/organizations/oauth2/v2.0/authorize
Microsoft token:
  https://login.microsoftonline.com/organizations/oauth2/v2.0/token
Microsoft Graph:
  https://graph.microsoft.com/v1.0
```

Microsoft uses the fixed `organizations` tenant for work/school accounts only;
Outlook.com personal accounts are not supported.
Authorization, token, and API endpoint overrides must be absolute HTTPS URLs
without credentials or fragments. Each provider is unavailable until a complete,
decryptable setting has been saved; a corrupt setting fails closed as a provider
configuration error.
Development and test configuration use non-production encryption keys;
development has no default provider client credentials and test uses inert
endpoints. Save Google or Microsoft credentials through Settings → OAuth before
exercising that provider in `MIX_ENV=dev`.
The configured Gmail OAuth consent screen must include the receive and send
scopes used by the application:

```text
Gmail:     openid email https://www.googleapis.com/auth/gmail.readonly
Gmail send:             https://www.googleapis.com/auth/gmail.send
Microsoft delegated permissions: User.Read, Mail.Read, and Mail.Send.
Microsoft durable refresh grant: offline_access.
```

Enable the Gmail API in the Google Cloud project before connecting an account.
Register the exact callback `https://<your-manifold-host>/connectors/gmail/callback`,
configure both Gmail scopes on the OAuth consent screen, and add development
accounts as test users while the app remains in testing mode. Keep
`MANIFOLD_CONNECTOR_ENCRYPTION_KEY` stable across deploys; rotating or losing it
without a credential migration makes stored OAuth credentials unreadable. Before
public use, complete Google's consent-screen publication and verification
requirements for the requested scopes. Never commit client credentials or use a
callback for a host other than the deployed Manifold endpoint.

The Settings routes currently inherit Manifold's trusted-local-instance boundary;
they are not an authenticated administrator surface. Network-exposed deployments
must add access control before treating browser-managed secrets as safe.

Register the exact Microsoft callback
`https://<host>/connectors/microsoft/callback`; local development uses
`http://localhost:4290/connectors/microsoft/callback`. The fixed `organizations`
tenant permits work/school accounts only. Restrict staging to a non-production
app registration, tenant, and approved test users, and obtain tenant admin
consent when the tenant's user-consent policy requires it. Save the client ID and
secret at `/settings/oauth`, using `/settings/oauth/microsoft/help` for the exact
deployed callback and required scopes. Existing receive-only accounts grant
`Mail.Send` incrementally when Send is added.
Provider acceptance is immediate in Send activity; the authoritative Sent copy
appears after normal/manual Graph polling when Receive is enabled. Back up
`MANIFOLD_CONNECTOR_ENCRYPTION_KEY`; changing it without a coordinated rotation
makes stored OAuth credentials unreadable.

## Account Send Methods

Each Manifold account can have one enabled send method. Gmail uses the Gmail API
with `gmail.send`; Microsoft uses direct MIME Graph `sendMail` with `Mail.Send`;
SMTP uses the configured relay host, TLS mode, username, and encrypted password.
A queued message permanently snapshots its method, sender address, and exact
provider MIME payload, so later settings or draft changes do not reroute it or
change retry bytes. All three methods render text-only RFC messages and preserve
reply headers.

If a provider response or process interruption makes acceptance ambiguous,
Manifold marks the message `submission_uncertain` and does not resend it
automatically. Reconcile the provider's Sent folder or SMTP relay state before
taking any manual action. Existing Resend submissions and webhooks remain
supported for legacy queued rows; new account-selected routing does not rewrite
them.

For Microsoft, a bodyless Graph `202` is provider acceptance, not recipient
delivery, and supplies no provider message ID. Send activity shows that state
immediately. Graph Sent Items imported through normal/manual polling is the
authoritative projected Sent copy; send-only accounts therefore have Send
activity without a projected Sent message.

### Non-rolling Gmail authorization cutover

The shared Gmail authorization migrations require a non-rolling deployment.
Before migrating, drain and stop every old Phoenix instance, connector worker,
and Oban worker. Run migrations only after no old process can create or refresh
connector state, then start the new release.

Rollback is intentionally guarded. Migration
`20260811000500_add_shared_gmail_authorizations.exs` first proves it can restore
legacy Gmail credentials losslessly and refuses unsafe rollback. Migration
`20260811000600_add_oauth_authorization_events.exs` requires each authorization
event to have exactly one legacy receive anchor. Migration
`20260811000700_enforce_provider_submission_methods.exs` refuses rollback while
Gmail or SMTP provider submissions exist. Do not bypass these preflights.

### Non-rolling OAuth provider-settings cutover

Migration `20260818000100_add_oauth_provider_settings.exs` was the original
non-rolling Gmail cutover. Before applying it, drain and stop every old Phoenix,
connector, and Oban process. It performs no environment import or fallback;
afterward Gmail is unavailable until Google credentials are saved at
`/settings/oauth`, and existing Gmail grants must reconnect.

The 2026-08-27 Microsoft catalog adoption is a separate code-only, non-rolling
cutover and adds no migration. Before deploying that binary, stop new Microsoft
submissions, drain all queued and executing Microsoft send work, then drain and
stop every old Phoenix instance, connector process, and Oban worker. After the
new binary starts, only Microsoft is unavailable until its credentials are saved
at `/settings/oauth`, and existing Microsoft grants and methods require
reconnect. The existing Google setting, grants, and methods remain valid and must
be left untouched: do not rotate or remove Google credentials as part of the
Microsoft cutover.

Before promoting staging, verify all of the following without restarting:

- saving Google or Microsoft credentials immediately enables that provider in
  both receive and send method pickers;
- each provider help page shows its deployed exact callback URI and required
  scopes;
- receive and provider send work with approved staging identities;
- secret rotation and client-ID change require reconnect, and removal disables
  the affected provider without deleting or revoking its remote grant;
- previously disabled or reconnect-required methods do not resume automatically.

#### Microsoft-only code rollback before the 2026-08-27 binary

The Microsoft Settings adoption added no migration, so rolling only the
application binary back to a pre-2026-08-27 release does not require rolling back
`20260818000100`. Leave the Google provider setting, grants, and methods in place;
do not rotate or remove Google for this rollback. The older binary ignores the
stored Microsoft provider setting and instead expects the exact historical
`MANIFOLD_MICROSOFT_CLIENT_ID`, `MANIFOLD_MICROSOFT_CLIENT_SECRET`, and
`MANIFOLD_MICROSOFT_TENANT` values.

Before switching binaries, verify the presence and provenance of that exact
historical Microsoft credential pair and tenant in the approved deployment
secret store without displaying their values. If they cannot be verified, either
stop the rollback or deliberately accept that Microsoft will be unavailable by
leaving both client credential variables absent. Never provide only half of the
pair, guess or recreate a credential or tenant, or delete the stored Settings row
directly. The database-backed Microsoft setting can remain for a later upgrade.

#### Full guarded rollback below `20260818000100`

Rollback of `20260818000100` is destructive and non-rolling. It drops the OAuth
provider-settings table and the setting-generation columns from OAuth transaction
history. Before any cleanup, block new OAuth starts, take a restorable database
backup, and keep the current release available for recovery. The Settings UI
removes only the provider-setting row; it deliberately does not delete OAuth
transactions. Consumed transaction history with a non-null setting UUID therefore
continues to block rollback just like an unfinished transaction.

Take a normal full database snapshot. If command-line PostgreSQL tooling is the
approved backup path, keep both a full dump and a narrow export in a private
directory; both contain sensitive connector data and must not be logged or
committed:

```sh
umask 077
rollback_dir="oauth-settings-rollback-backup-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 0700 "$rollback_dir"
PGDATABASE="$DATABASE_URL" pg_dump \
  --format=custom \
  --file="$rollback_dir/manifold.dump"
PGDATABASE="$DATABASE_URL" pg_dump \
  --format=custom \
  --data-only \
  --table=public.connector_oauth_provider_settings \
  --table=public.connector_oauth_transactions \
  --file="$rollback_dir/oauth-settings-tables.dump"
test -s "$rollback_dir/manifold.dump"
test -s "$rollback_dir/oauth-settings-tables.dump"
sha256sum "$rollback_dir/manifold.dump" "$rollback_dir/oauth-settings-tables.dump"
```

Verify the dump files exist and record their checksums according to the deployment
backup policy. The narrow dump can be restored only after the provider-settings
migration has been reapplied; it is not compatible with the rolled-back schema.

While one current-version Phoenix instance is still available, remove every
configured OAuth provider setting through `/settings/oauth`. Explicitly remove
both Google and Microsoft when present, using each provider's normal confirmed
removal action so the supported lifecycle marks its dependent grants and methods
reconnect-required. Do not proceed until every catalog provider shows **Not
configured**; a surviving Microsoft setting would block the zero-row preflight
below. If the UI cannot remove any remaining setting, stop and restore a
compatible release; do not bypass lifecycle effects with a direct table delete.
Then drain and stop every Phoenix instance, connector process, and Oban worker
before inspecting or changing the database.

Use the deployment's approved libpq service and passfile for SQL sessions. If the
deployment supplies only `DATABASE_URL`, pass it through libpq's environment
rather than exposing the URI in process arguments:

```sh
PGDATABASE="$DATABASE_URL" psql --set=ON_ERROR_STOP=1
```

Do not echo `DATABASE_URL` or include it as a positional `psql`/`pg_dump`
argument.

Run these read-only queries first:

```sql
SELECT id, provider, client_id, key_version, lock_version, inserted_at, updated_at
FROM connector_oauth_provider_settings
ORDER BY provider;

SELECT
  COUNT(*) AS provider_setting_rows
FROM connector_oauth_provider_settings;

SELECT
  COUNT(*) AS fenced_transaction_rows,
  COUNT(*) FILTER (WHERE consumed_at IS NULL) AS unfinished_fenced_rows,
  COUNT(*) FILTER (WHERE consumed_at IS NOT NULL) AS consumed_fenced_rows
FROM connector_oauth_transactions
WHERE oauth_provider_setting_id IS NOT NULL;

SELECT
  id,
  provider,
  mailbox_id,
  purpose,
  oauth_provider_setting_id,
  oauth_provider_setting_lock_version,
  consumed_at,
  expires_at,
  inserted_at
FROM connector_oauth_transactions
WHERE oauth_provider_setting_id IS NOT NULL
ORDER BY inserted_at, id;

SELECT version
FROM schema_migrations
WHERE version >= 20260818000100
ORDER BY version;
```

Proceed only when `provider_setting_rows` is zero and the schema query returns
exactly `20260818000100`. If a setting remains or any later migration is applied,
stop; this runbook does not authorize deleting the setting directly or rolling
back later migrations.

Before any destructive `DELETE`, decide which providers the older release must
keep operational and verify their exact historical values through the approved
deployment secret store without displaying them. Gmail requires the original
`MANIFOLD_GMAIL_CLIENT_ID`/`MANIFOLD_GMAIL_CLIENT_SECRET` pair. Microsoft requires
the original `MANIFOLD_MICROSOFT_CLIENT_ID`/
`MANIFOLD_MICROSOFT_CLIENT_SECRET` pair and `MANIFOLD_MICROSOFT_TENANT`. If both
providers must continue, all five provider values must have verified provenance
and be recoverable. Also confirm that the exact existing
`MANIFOLD_CONNECTOR_ENCRYPTION_KEY` and its secret-store version are retained; the
older release still needs that unchanged key to decrypt preserved connector
credentials.

If any value required for a provider is missing or its provenance is uncertain,
stop and do not delete transaction history. A provider that does not need to
continue may instead be deliberately left unavailable by omitting its complete
credential set; never supply a partial pair, guess or recreate a credential or
tenant, or copy values from the Settings ciphertext. These environment names are
rollback-only compatibility for a release that predates Settings-managed Google
and Microsoft credentials. The current release ignores them; they are not a
current configuration source, import path, or fallback.

Deleting fenced transactions permanently destroys one-time OAuth state and its
consumed audit history. Only after the operator has reviewed the transaction list,
confirmed that losing every returned row is acceptable, and verified the backup,
run this narrowly scoped transaction. Review the `RETURNING` output before issuing
`COMMIT`; do not paste a commit together with the delete:

```sql
BEGIN;

DELETE FROM connector_oauth_transactions
WHERE oauth_provider_setting_id IS NOT NULL
RETURNING
  id,
  provider,
  mailbox_id,
  purpose,
  oauth_provider_setting_id,
  oauth_provider_setting_lock_version,
  consumed_at,
  expires_at,
  inserted_at;
```

If any returned row is unexpected, preserve the backup and abort with:

```sql
ROLLBACK;
```

Only when every returned row matches the reviewed list, commit separately:

```sql
COMMIT;
```

Repeat the count and schema-version queries. Both row counts must be zero and the
only version at or above the target must still be `20260818000100`. With all
application processes still stopped, a development checkout can then roll back
the target migration with:

```sh
devenv shell -- mix ecto.rollback --to 20260818000100
```

The main release currently has no `Manifold.Release` migration API. Do not call
`Manifold.Edge.Release`, which operates on the separate edge database. The main
release equivalent follows the existing edge release's `Ecto.Migrator.with_repo/2`
pattern but targets `Manifold.Repo` and the `manifold_data` migration directory:

```sh
bin/manifold eval '
:ok = Application.ensure_loaded(:manifold_data)
path = Application.app_dir(:manifold_data, "priv/repo/migrations")
{:ok, migrated, _apps} =
  Ecto.Migrator.with_repo(Manifold.Repo, fn repo ->
    Ecto.Migrator.run(repo, path, :down, to: 20260818000100)
  end)
IO.inspect(migrated, label: "rolled_back")
'
```

Require `rolled_back: [20260818000100]`, then run these post-rollback verification
queries before starting the older release:

```sql
SELECT to_regclass('connector_oauth_provider_settings') AS provider_settings_table;

SELECT column_name
FROM information_schema.columns
WHERE table_schema = current_schema()
  AND table_name = 'connector_oauth_transactions'
  AND column_name IN (
    'oauth_provider_setting_id',
    'oauth_provider_setting_lock_version'
  )
ORDER BY column_name;

SELECT version
FROM schema_migrations
WHERE version = 20260818000100;
```

The first result must be `NULL`, and the other two queries must return no rows.
Any unexpected result is a stop condition; restore the backup or the compatible
release rather than forcing the migration guard.

Before starting the older release, restore/export each required, provenance-
verified provider set through the deployment's approved secret mechanism and bind
the same, unchanged connector encryption-key secret version. If both Google and
Microsoft must remain operational, verify all of these values are present without
printing them in the exact environment that will launch the older release:

```sh
test -n "${MANIFOLD_GMAIL_CLIENT_ID:-}" || {
  echo "MANIFOLD_GMAIL_CLIENT_ID is missing" >&2
  exit 1
}
test -n "${MANIFOLD_GMAIL_CLIENT_SECRET:-}" || {
  echo "MANIFOLD_GMAIL_CLIENT_SECRET is missing" >&2
  exit 1
}
test -n "${MANIFOLD_MICROSOFT_CLIENT_ID:-}" || {
  echo "MANIFOLD_MICROSOFT_CLIENT_ID is missing" >&2
  exit 1
}
test -n "${MANIFOLD_MICROSOFT_CLIENT_SECRET:-}" || {
  echo "MANIFOLD_MICROSOFT_CLIENT_SECRET is missing" >&2
  exit 1
}
test -n "${MANIFOLD_MICROSOFT_TENANT:-}" || {
  echo "MANIFOLD_MICROSOFT_TENANT is missing" >&2
  exit 1
}
test -n "${MANIFOLD_CONNECTOR_ENCRYPTION_KEY:-}" || {
  echo "MANIFOLD_CONNECTOR_ENCRYPTION_KEY is missing" >&2
  exit 1
}
```

If a provider is intentionally unavailable, omit its complete credential set and
document that outcome; never launch with only one client credential or an
unverified tenant. Presence alone does not prove provenance or key continuity.
Separately compare provider secret metadata and the connector-key secret-store
version with the recorded pre-rollback versions, without printing values. Start
the older release only after every required provider set is verified and the
connector key is confirmed unchanged.

## Development

Enter the reproducible shell:

```sh
devenv shell
```

On first setup, start PostgreSQL in one terminal:

```sh
devenv processes start postgres
```

Then set up dependencies and migrations from another terminal:

```sh
devenv shell -- mix setup
```

Frontend assets use Duskmoon Bundler and `duskmoon_npm`; `mix setup` runs
`mix npm.install`. Use `mix assets.build` during development and
`MIX_ENV=prod mix assets.deploy` for production assets.

No sample mailbox is seeded. Create a domain and mailbox from `/mailboxes`
after the app is running.

The web interface has no application-level authentication. Anyone who can reach
the Phoenix endpoint has full access to the local Manifold instance, so network
access must be restricted by the host or a trusted reverse proxy.

Run migrations only:

```sh
mix ecto.migrate
```

Start the mail-client runtime:

```sh
devenv processes start
```

The managed Manifold process runs pending Ecto migrations after PostgreSQL is
ready and before starting the application.

Open Phoenix at `http://localhost:4290`; the API listens at
`http://localhost:4292`. The separate `manifold_edge` release owns inbound SMTP.
The root page is the mailbox inbox; transport lifecycle details remain under
`/deliveries`.

Resend configuration is retained only for legacy rows already queued with
`provider = 'resend'` and their webhook lifecycle. If such rows exist, set
`RESEND_API_KEY` and configure the Resend webhook endpoint as:

```text
https://<your-manifold-host>/webhooks/providers/resend
```

Set `RESEND_WEBHOOK_SECRET` to the endpoint signing secret. An optional
`RESEND_API_BASE_URL` is supported for controlled testing. New drafts never
select Resend: each account must have an enabled Gmail, Microsoft, or SMTP send
method before it can queue mail.

SMTP abuse limits can be tuned with
`MANIFOLD_SMTP_MAX_CONNECTIONS_PER_PEER`,
`MANIFOLD_SMTP_CONNECTION_RATE_LIMIT`,
`MANIFOLD_SMTP_CONNECTION_RATE_WINDOW_MS`,
`MANIFOLD_SMTP_TRANSACTION_RATE_LIMIT`, and
`MANIFOLD_SMTP_TRANSACTION_RATE_WINDOW_MS`.

## Optional Cloud Ingress

Build both releases with:

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release manifold
MIX_ENV=prod mix release manifold_edge
```

The edge release requires:

```text
MANIFOLD_ROLE=edge
MANIFOLD_EDGE_DATABASE_URL
MANIFOLD_EDGE_API_URL=https://edge.example.com
MANIFOLD_EDGE_INSTALLATION_ID
MANIFOLD_EDGE_SHARED_SECRET
MANIFOLD_SPOOL_DIR
MANIFOLD_SMTP_HOSTNAME
```

Generate a shared secret with at least 32 random bytes, for example:

```sh
openssl rand -hex 32
```

Run edge-only migrations before startup:

```sh
bin/manifold_edge eval 'Manifold.Edge.Release.migrate()'
```

The edge API binds to `127.0.0.1:4291` by default and must be published only
through a trusted HTTPS reverse proxy matching `MANIFOLD_EDGE_API_URL`. Set
`MANIFOLD_EDGE_API_BIND` only when the host firewall provides an equivalent
boundary. SMTP defaults to port `25` in the edge release.

Configure the local release with the same `MANIFOLD_EDGE_API_URL`,
`MANIFOLD_EDGE_INSTALLATION_ID`, and `MANIFOLD_EDGE_SHARED_SECRET`, plus a stable
`MANIFOLD_EDGE_SOURCE_ID`. The local Oban queues publish routes every five
minutes and pull pending deliveries every minute. Operators can queue either
operation from `/cloud`.

Run checks:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

## SMTP Durability

Manifold returns SMTP `250` only after the raw message and manifest have been written and fsynced into a ready spool bundle, the bundle has been atomically renamed into `ready/`, the PostgreSQL acceptance transaction has committed, and the first Oban archival job has been inserted in that same transaction.

If the connection fails before `250`, the sender may retry and create a legitimate duplicate delivery. Manifold does not hard-delete possible duplicates based on `Message-ID` or content hash.

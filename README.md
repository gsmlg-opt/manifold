# Manifold

Manifold is a self-hosted Phoenix webmail application backed by an Elixir-native
mail platform. The main runtime acts as a mail client for provider-hosted
accounts; the optional `manifold_edge` release provides durable inbound SMTP for
installations that deploy it.

## Milestones 0-6

Milestones 0-6 implement durable inbound delivery, mailbox projection, managed
outbound submission, fail-closed inbound policy, optional cloud ingress,
read-only Gmail and Microsoft 365 synchronization, and account-selected Gmail
API or SMTP submission:

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
- Atomic outbound queueing with Oban, frozen account send-method snapshots,
  Gmail API and authenticated SMTP submission, and legacy Resend compatibility.
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

## Out Of Scope

The current milestones intentionally do not implement rich-text composition,
outbound attachments, bundled DNS authentication engines, bundled spam or
malware engines, POP3, JMAP, provider push notifications, Gmail or Microsoft
mailbox mutation, Microsoft Graph sending, or cloud provider hosting.
Read-only IMAP and Exchange ActiveSync (EAS) Inbox import are supported via the
connectors application; POP3 and JMAP remain out of scope. Production
authentication and scanning engines
plug into the Milestone 4 adapter boundaries. The optional edge is ingress-only
and never performs outbound MX delivery.

Manifold never performs direct outbound Internet MX delivery. Outbound messages
use the sending account's frozen Gmail API or authenticated SMTP method. Legacy
Resend submissions remain supported for messages queued with that provider
shape. Microsoft Graph remains receive-only.

## External Mailbox Connectors

Milestone 6 imports provider-hosted mail into an existing local Manifold
mailbox. It does not make Gmail or Microsoft 365 the metadata source of truth
for Manifold and does not bypass the durable local acceptance pipeline.

The current implementation includes:

- Purpose-scoped OAuth authorization-code primitives with one-time, hashed state
  and PKCE `S256`; Gmail receive and send grants incrementally share one
  authorization record.
- AES-256-GCM encryption envelopes for access tokens, refresh tokens, and PKCE
  verifiers. Encryption binds each secret to its account and purpose.
- Gmail OpenID identity, message-list, history, and `format=RAW` operations
  using the stable subject identifier and `gmail.readonly` scope. The shared
  authorization can also hold `gmail.send` for outbound Gmail API submission.
- Microsoft Graph profile, folder-delta, message-delta, immutable message ID,
  and `/$value` raw-message operations using `Mail.Read`.
- Transactional account, credential, cursor, event, and first Oban sync-job
  persistence after OAuth completion.
- Bounded, retryable sync pages with provider-message identity and cursor
  checkpointing only after every message in the page has crossed the local
  acceptance boundary.
- Idempotent external import through a version-2 spool bundle, raw archive,
  mailbox projection, and a retryable remote-state application job.
- A no-auth `/settings/accounts` LiveView with OAuth start/callback routes,
  sync-now, status, and disconnect controls.
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
MANIFOLD_GMAIL_CLIENT_ID
MANIFOLD_GMAIL_CLIENT_SECRET
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

`MANIFOLD_CONNECTOR_ENCRYPTION_KEY` must be standard Base64 encoding of exactly
32 random bytes and is required for the production local release even when no
provider client is configured. Generate one with:

```sh
openssl rand -base64 32
```

The provider application registrations will use these exact callback paths:

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
  https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize
Microsoft token:
  https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token
Microsoft Graph:
  https://graph.microsoft.com/v1.0
```

Use `organizations` as the Microsoft tenant default for work/school accounts.
Authorization, token, and API endpoint overrides must be absolute HTTPS URLs
without credentials or fragments. A provider is enabled only when its client ID
and secret are both set; configuring only one makes startup fail.
Development and test configuration use non-production encryption keys;
development has no provider client credentials and test uses inert endpoints.
Set the provider client environment variables before
`devenv processes start` to exercise a real provider in `MIX_ENV=dev`.
The configured Gmail OAuth consent screen must include the receive and send
scopes used by the application:

```text
Gmail:     openid email https://www.googleapis.com/auth/gmail.readonly
Gmail send:             https://www.googleapis.com/auth/gmail.send
Microsoft: openid profile offline_access User.Read Mail.Read
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

## Account Send Methods

Each Manifold account can have one enabled send method. Gmail uses the Gmail API
with `gmail.send`; SMTP uses the configured relay host, TLS mode, username, and
encrypted password. A queued message permanently snapshots its method and sender
address, so later settings changes do not reroute it. Gmail and SMTP render
text-only RFC messages and preserve reply headers.

If a provider response or process interruption makes acceptance ambiguous,
Manifold marks the message `submission_uncertain` and does not resend it
automatically. Reconcile the provider's Sent folder or SMTP relay state before
taking any manual action. Existing Resend submissions and webhooks remain
supported for legacy queued rows; new account-selected routing does not rewrite
them.

### Non-rolling Gmail authorization cutover

The shared Gmail authorization migrations require a non-rolling deployment.
Before migrating, drain and stop every old Phoenix instance, connector worker,
and Oban worker. Run migrations only after no old process can create or refresh
connector state, then start the new release.

Rollback is intentionally guarded. Migration
`20260811000100_add_shared_gmail_authorizations.exs` first proves it can restore
legacy Gmail credentials losslessly and refuses unsafe rollback. Migration
`20260811000200_add_oauth_authorization_events.exs` requires each authorization
event to have exactly one legacy receive anchor. Migration
`20260811000300_enforce_provider_submission_methods.exs` refuses rollback while
Gmail or SMTP provider submissions exist. Do not bypass these preflights.

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
select Resend: each account must have an enabled Gmail or SMTP send method before
it can queue mail.

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

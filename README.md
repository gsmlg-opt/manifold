# Manifold

Manifold is a self-hosted Phoenix webmail application backed by an Elixir-native
mail platform. It is designed to replace a desktop email client for locally
hosted mailboxes while preserving durable SMTP acceptance and raw message data.

## Milestones 0-6

Milestones 0-6 implement durable inbound delivery, mailbox projection, managed
outbound submission, fail-closed inbound policy, optional cloud ingress, and
read-only Gmail and Microsoft 365 synchronization:

- Phoenix umbrella with explicit Core, Data, Accounts, Storage, Ingest, SMTP,
  Mail, Security, Outbound, Cloud, Edge, Connectors, and Web application
  boundaries.
- Optional `manifold_edge` release and local `manifold_cloud` pull client.
- PostgreSQL/Ecto migrations and Oban jobs.
- Domain, mailbox, alias, alias target, and recipient resolution.
- `gen_smtp` development listener on port `2525`.
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
- Atomic outbound queueing with Oban, stable provider idempotency, and a Resend
  HTTPS adapter.
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
malware engines, IMAP, POP3, JMAP, provider push notifications, Gmail or
Microsoft mailbox mutation, provider-backed sending, or cloud provider hosting.
Production authentication and scanning engines plug into the Milestone 4
adapter boundaries. The optional edge is ingress-only and never performs
outbound MX delivery.

Manifold never performs direct outbound Internet SMTP delivery. Milestone 3
submits locally composed mail through the configured managed-provider HTTPS
adapter. The Milestone 6 Gmail and Microsoft adapters are read-only and are not
outbound providers.

## External Mailbox Connectors

Milestone 6 imports provider-hosted mail into an existing local Manifold
mailbox. It does not make Gmail or Microsoft 365 the metadata source of truth
for Manifold and does not bypass the durable local acceptance pipeline.

The current implementation includes:

- Microsoft OAuth Device Authorization Grant (RFC 8628) for public clients
  (`client_id` only; same public-client idea as a desktop mail app).
- Gmail authorization-code + PKCE `S256` (Google's device-flow allowlist
  excludes Gmail API scopes). Prefer a Desktop/public Google client so
  `client_secret` is optional.
- One-time, hashed OAuth state; encrypted device codes or PKCE verifiers.
- AES-256-GCM encryption envelopes for access tokens, refresh tokens, and
  temporary OAuth secrets. Encryption binds each secret to its account and
  purpose.
- Gmail OpenID identity, message-list, history, and `format=RAW` operations
  using the stable subject identifier and `gmail.readonly` scope.
- Microsoft Graph profile, folder-delta, message-delta, immutable message ID,
  and `/$value` raw-message operations using `Mail.Read`.
- Transactional account, credential, cursor, event, and first Oban sync-job
  persistence after OAuth completion.
- Bounded, retryable sync pages with provider-message identity and cursor
  checkpointing only after every message in the page has crossed the local
  acceptance boundary.
- Idempotent external import through a version-2 spool bundle, raw archive,
  mailbox projection, and a retryable remote-state application job.
- A no-auth `/settings/accounts` LiveView with Gmail OAuth start/callback
  routes, Microsoft device-code UX, sync-now, status, and disconnect controls.
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

Each provider account identity is permanently bound to the local mailbox chosen
at first connection. Reauthorization refreshes that account but cannot silently
move it to a different mailbox.

### Provider Configuration

The local release and development runtime support:

```text
MANIFOLD_CONNECTOR_ENCRYPTION_KEY
MANIFOLD_GMAIL_CLIENT_ID
MANIFOLD_GMAIL_CLIENT_SECRET          # optional for public/Desktop clients
MANIFOLD_GMAIL_AUTHORIZATION_URL
MANIFOLD_GMAIL_TOKEN_URL
MANIFOLD_GMAIL_USERINFO_URL
MANIFOLD_GMAIL_API_BASE_URL
MANIFOLD_MICROSOFT_CLIENT_ID
MANIFOLD_MICROSOFT_CLIENT_SECRET      # optional for public clients
MANIFOLD_MICROSOFT_TENANT
MANIFOLD_MICROSOFT_DEVICE_CODE_URL
MANIFOLD_MICROSOFT_TOKEN_URL
MANIFOLD_MICROSOFT_API_BASE_URL
```

`MANIFOLD_CONNECTOR_ENCRYPTION_KEY` must be standard Base64 encoding of exactly
32 random bytes and is required for the production local release even when no
provider client is configured. Generate one with:

```sh
openssl rand -base64 32
```

A commented variable checklist lives in `.env.example`. With devenv, `.env` is
sourced automatically; outside devenv export the variables before starting the
app (`set -a && source .env && set +a`).

Gmail still needs a redirect callback (authorization code + PKCE):

```text
https://<your-manifold-host>/connectors/gmail/callback
```

Local development:

```text
http://localhost:4290/connectors/gmail/callback
```

Microsoft uses device authorization and does not require a redirect URI.
Development Endpoint `:url` includes port `4290` so Gmail redirect URIs match
local callback registrations.

The provider configuration uses:

```text
Gmail authorization: https://accounts.google.com/o/oauth2/v2/auth
Gmail token:         https://oauth2.googleapis.com/token
Gmail API:           https://gmail.googleapis.com

Microsoft device code:
  https://login.microsoftonline.com/<tenant>/oauth2/v2.0/devicecode
Microsoft token:
  https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token
Microsoft Graph:
  https://graph.microsoft.com/v1.0
```

Use `organizations` as the Microsoft tenant default for work/school accounts.
Endpoint overrides must be absolute HTTPS URLs without credentials or fragments.
A provider is enabled when its `client_id` and required endpoint URLs are set;
`client_secret` is optional. Setting a secret without a client ID fails startup.
Development and test configuration use non-production encryption keys;
development has no provider client credentials and test uses inert endpoints.
Set the provider client environment variables before
`devenv processes start` to exercise a real provider in `MIX_ENV=dev`.
The requested read-only scopes are:

```text
Gmail:     openid email https://www.googleapis.com/auth/gmail.readonly
Microsoft: openid profile offline_access User.Read Mail.Read
```

### Compared with Apple Mail

Apple Mail (and similar desktop clients) also uses **OAuth user consent** with a
**public/native client**: you pick Google or Outlook, sign in in a system or
browser sheet, and the app never stores your provider password. Under the hood
Apple then talks **IMAP/SMTP + XOAUTH2** (or Exchange protocols)—not the Gmail
API or Microsoft Graph.

Manifold mirrors that **user-facing OAuth model** (register your own public
client, typically `client_id` only, then sign in / approve):

| | Apple Mail | Manifold Milestone 6 |
| --- | --- | --- |
| User consent | OAuth (system/browser) | OAuth (browser for Gmail; device code for Microsoft) |
| Client type | Apple’s native/public app | **Your** public/Desktop or public Entra app |
| Sync channel | IMAP / Exchange | Gmail API + Microsoft Graph (read-only) |
| `client_secret` | Not an operator concern | Optional; leave unset for public clients |

Do **not** reuse Apple Mail’s (or any other vendor’s) OAuth `client_id` or
secret. That violates provider terms, and redirect or device registration will
not match Manifold. IMAP as the first connector remains rejected (see
[ADR 0007](docs/adr/0007-read-only-provider-connectors.md)).

### Google Cloud OAuth client (Gmail)

Google’s documented OAuth device-flow allowlist does **not** include Gmail API
scopes, so Manifold cannot use device authorization for Gmail. Use authorization
code + PKCE instead.

1. In Google Cloud Console, create or select a project.
2. Enable the Gmail API for that project.
3. Configure the OAuth consent screen (External or Internal). Add the test
   users who will connect during development if the app is in Testing.
4. Create an OAuth client ID. Prefer **Desktop app** / installed for a public
   client (`client_id` only). A **Web application** client also works and may
   include a secret.
5. For Web clients, add the authorized redirect URI
   `http://localhost:4290/connectors/gmail/callback` for local use, and the
   production HTTPS callback for a deployed host. Desktop clients use the
   loopback redirect generated by Manifold’s Endpoint URL.
6. Copy the client ID into `MANIFOLD_GMAIL_CLIENT_ID`. Set
   `MANIFOLD_GMAIL_CLIENT_SECRET` only when the Google client has a secret.
7. Scopes requested by Manifold:
   `openid`, `email`, and
   `https://www.googleapis.com/auth/gmail.readonly`. Offline access is
   requested via `access_type=offline` and `prompt=consent`.

### Azure AD app registration (Microsoft 365)

1. In Microsoft Entra ID (Azure AD), register a new application.
2. Under **Authentication** → **Advanced settings**, set **Allow public client
   flows** to **Yes**. No redirect URI is required for device code flow.
3. Under **API permissions**, add Microsoft Graph **delegated** permissions:
   `openid`, `profile`, `offline_access`, `User.Read`, and `Mail.Read`.
   Do not add `Mail.ReadWrite` or `Mail.Send`.
4. Grant admin consent if your tenant requires it for `Mail.Read`.
5. Copy the Application (client) ID into `MANIFOLD_MICROSOFT_CLIENT_ID`.
   A client secret is optional for this public-client device flow.
6. Set `MANIFOLD_MICROSOFT_TENANT` to `organizations` (default, work/school),
   a specific tenant ID/domain, or `common` only when personal accounts must
   be allowed.

### Connect and smoke-test from the UI

1. Ensure at least one local mailbox exists (`mix setup` seeds
   `inbox@example.test`, or create one under `/mailboxes`).
2. Open `http://localhost:4290/settings/accounts` → **Add account**.
3. Choose **External account**, then **Gmail** or **Microsoft 365** (disabled
   providers mean the matching env vars are not loaded — only `client_id` is
   required).
4. Select the destination local mailbox and continue:
   - **Gmail** → **Sign in with Google** (browser consent, then callback).
   - **Microsoft 365** → **Sign in with Microsoft** (device user code +
     verification URI; approve on any device while Manifold polls).
5. After authorization, the account should appear as connected and the first
   sync job is inserted. Use **Synchronize now** if needed; wait for mail to
   show in the chosen mailbox inbox.
6. Use **Disconnect** to revoke the local connection (provider-side consent
   may remain until removed in the provider account settings).

Minimal env for a mail-client-style setup (placeholders only):

```text
MANIFOLD_GMAIL_CLIENT_ID=your-desktop-client-id.apps.googleusercontent.com
MANIFOLD_MICROSOFT_CLIENT_ID=00000000-0000-0000-0000-000000000000
# secrets intentionally omitted
```

## Development

Enter the reproducible shell:

```sh
devenv shell
```

On first setup, start PostgreSQL in one terminal:

```sh
devenv processes start postgres
```

Then set up dependencies, migrations, and a sample mailbox from another terminal:

```sh
devenv shell -- mix setup
```

Frontend assets use Duskmoon Bundler and `duskmoon_npm`; `mix setup` runs
`mix npm.install`. Use `mix assets.build` during development and
`MIX_ENV=prod mix assets.deploy` for production assets.

The development seed creates the `example.test` domain and `inbox@example.test` mailbox.

The web interface has no application-level authentication. Anyone who can reach
the Phoenix endpoint has full access to the local Manifold instance, so network
access must be restricted by the host or a trusted reverse proxy.

Run migrations only:

```sh
mix ecto.migrate
```

Start Phoenix and the SMTP listener:

```sh
devenv processes start
```

The managed Manifold process runs pending Ecto migrations after PostgreSQL is
ready and before starting the application.

Open Phoenix at `http://localhost:4290`. Submit SMTP mail to `127.0.0.1:2525`.
The root page is the mailbox inbox; transport lifecycle details remain under
`/deliveries`.

To enable outbound delivery through Resend, set `RESEND_API_KEY` and configure
the Resend webhook endpoint as:

```text
https://<your-manifold-host>/webhooks/providers/resend
```

Set `RESEND_WEBHOOK_SECRET` to the endpoint signing secret. An optional
`RESEND_API_BASE_URL` is supported for controlled testing. Without an API key,
drafts remain usable but queued submissions fail with a classified
`provider_not_configured` state instead of making a network request.

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

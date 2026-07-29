# Manifold

Manifold is a self-hosted Phoenix webmail application backed by an Elixir-native
mail platform. It is designed to replace a desktop email client for locally
hosted mailboxes while preserving durable SMTP acceptance and raw message data.

## Milestones 0-5

This repository currently implements durable inbound delivery, mailbox
projection, managed outbound submission, and fail-closed inbound policy:

- Phoenix umbrella with `manifold_core`, `manifold_data`, `manifold_accounts`,
  `manifold_storage`, `manifold_ingest`, `manifold_smtp`, `manifold_mail`,
  `manifold_security`, `manifold_outbound`, and `manifold_web`.
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

## Out Of Scope

The current milestones intentionally do not implement rich-text composition,
outbound attachments, bundled DNS authentication engines, bundled spam or
malware engines, IMAP, POP3, JMAP, Gmail sync, Microsoft Graph sync, or cloud
provider hosting. Production authentication and scanning engines plug into the
Milestone 4 adapter boundaries. The optional edge is ingress-only and never
performs outbound MX delivery.

Manifold never performs direct outbound Internet SMTP delivery. Milestone 3
submits through the configured managed-provider HTTPS adapter.

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

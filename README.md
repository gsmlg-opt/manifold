# Manifold

Manifold is a self-hosted Phoenix webmail application backed by an Elixir-native
mail platform. It is designed to replace a desktop email client for locally
hosted mailboxes while preserving durable SMTP acceptance and raw message data.

## Milestones 0-2

This repository currently implements durable inbound delivery and its first
mail-client projection:

- Phoenix umbrella with `manifold_core`, `manifold_data`, `manifold_accounts`, `manifold_storage`, `manifold_ingest`, `manifold_smtp`, `manifold_mail`, and `manifold_web`.
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
- Isolated sanitized HTML rendering and mailbox-scoped attachment downloads.
- Operational LiveViews for domains, mailboxes, aliases, inbound deliveries, and
  delivery detail.

## Out Of Scope

The current milestones intentionally do not implement composition, drafts,
reply/forward, spam or malware scanning, IMAP, POP3, JMAP, Gmail sync, Microsoft
Graph sync, cloud relay, or managed outbound provider submission.

Manifold must not perform direct outbound Internet SMTP delivery. Outbound delivery is reserved for a future managed-provider adapter.

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

Run checks:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

## SMTP Durability

Manifold returns SMTP `250` only after the raw message and manifest have been written and fsynced into a ready spool bundle, the bundle has been atomically renamed into `ready/`, the PostgreSQL acceptance transaction has committed, and the first Oban archival job has been inserted in that same transaction.

If the connection fails before `250`, the sender may retry and create a legitimate duplicate delivery. Manifold does not hard-delete possible duplicates based on `Message-ID` or content hash.

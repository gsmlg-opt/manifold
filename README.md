# Manifold

Manifold is a self-hosted Phoenix webmail application backed by an Elixir-native
mail platform. It is designed to replace a desktop email client for locally
hosted mailboxes while preserving durable SMTP acceptance and raw message data.

## Milestone 0-1

This repository currently implements the first vertical slice:

- Phoenix umbrella with `manifold_core`, `manifold_data`, `manifold_accounts`, `manifold_storage`, `manifold_ingest`, `manifold_smtp`, and `manifold_web`.
- PostgreSQL/Ecto migrations and Oban jobs.
- Domain, mailbox, alias, alias target, and recipient resolution.
- `gen_smtp` development listener on port `2525`.
- Durable spool bundles under `tmp/`, `ready/`, `failed/`, and `quarantine/`.
- Local filesystem raw-message store.
- Minimal local-instance LiveViews for domains, mailboxes, aliases, inbound deliveries, and delivery detail.

## Out Of Scope

This milestone intentionally does not implement MIME parsing, body rendering, spam or malware scanning, IMAP, POP3, JMAP, Gmail sync, Microsoft Graph sync, cloud relay, managed outbound provider submission, or direct outbound MX delivery.

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
`mix npm.install`, and production assets are built with `MIX_ENV=prod mix assets.deploy`.

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

Run checks:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

## SMTP Durability

Manifold returns SMTP `250` only after the raw message and manifest have been written and fsynced into a ready spool bundle, the bundle has been atomically renamed into `ready/`, the PostgreSQL acceptance transaction has committed, and the first Oban archival job has been inserted in that same transaction.

If the connection fails before `250`, the sender may retry and create a legitimate duplicate delivery. Manifold does not hard-delete possible duplicates based on `Message-ID` or content hash.

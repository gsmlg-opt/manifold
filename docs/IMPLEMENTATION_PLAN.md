# Manifold Milestone 0-1 Implementation Plan

**Status:** Completed

## Scope

This plan covers only the first inbound vertical slice:

1. Reproducible Elixir/Phoenix umbrella repository.
2. PostgreSQL/Ecto/Oban persistence foundation.
3. Domains, mailboxes, aliases, and deterministic recipient resolution.
4. Durable local spool before SMTP acknowledgement.
5. Atomic acceptance transaction and transactional archival job.
6. Local filesystem raw-message store.
7. Development SMTP listener on port 2525.
8. Minimal local-instance Phoenix LiveView operational views.
9. Focused tests for routing, persistence, SMTP responses, archival retry, and crash boundaries.

The implementation intentionally excludes MIME parsing, message body rendering, direct outbound MX delivery, managed outbound providers, IMAP, POP3, JMAP, Gmail/Microsoft sync, cloud relay, and anti-spam/security engines.

## Architecture Steps

1. Bootstrap an umbrella with the required applications and enforce one-way dependencies.
   - Verify: `mix deps.get`, `mix compile`.
2. Add `manifold_data` with `Manifold.Repo`, centralized migrations, Oban configuration, and database health helpers.
   - Verify: `mix ecto.create`, `mix ecto.migrate`.
3. Add `manifold_core` pure address/domain/error/state modules.
   - Verify: address and transition unit tests.
4. Add `manifold_accounts` schemas and public APIs for domain, mailbox, alias, alias target, and recipient resolution.
   - Verify: account resolver tests cover exact, alias, plus, disabled, unknown, and deterministic ordering.
5. Add `manifold_storage` spool and raw-store boundaries with a local filesystem adapter.
   - Verify: spool tests cover manifest round trips, atomic ready transitions, path safety, cleanup, and orphan classification.
6. Add `manifold_ingest` schemas, acceptance `Ecto.Multi`, transactional Oban archival job insertion, archival worker, and reconciler.
   - Verify: ingest tests cover row creation, deduped mailbox entries, transactional job insertion, idempotency, retry, and crash boundaries.
7. Add `manifold_smtp` thin `gen_smtp` adapter and response mapping.
   - Verify: TCP integration tests cover known/unknown recipients, limits, temporary failures, and EHLO capabilities.
8. Add `manifold_web` with Phoenix LiveView and operational list/detail pages through public context APIs.
   - Verify: web tests cover direct local access, context-backed detail loading, and no raw public URLs.
9. Add Nix/devenv files, Mix aliases, CI workflow, seed helpers, and documentation.
   - Verify: `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix test`.

## Key Invariants

- SMTP `250` is returned only after the ready spool bundle exists, the acceptance transaction commits, and the archival job is inserted in that same transaction.
- Sender-controlled values never become filesystem path components.
- Recipient resolution rejects unknown local recipients during `RCPT TO`; temporary account/database failures map to transient SMTP responses.
- All original accepted `RCPT TO` records are retained, while mailbox entries are deduplicated per delivery and mailbox.
- Raw `.eml` bytes remain the source of truth. Parsed mail projections are out of scope.
- Frozen recipient routes must be non-empty and match the durable spool manifest before acceptance.
- Oban archival is idempotent and leaves the ready spool bundle in place until archived state and object verification both succeed.
- Reconciliation repairs interrupted archival, restores reappearing bundles, and never imports an orphan as accepted mail.
- PubSub may refresh UI state only; durable work is driven by database state and Oban.

# Manifold Milestone 2 Implementation Plan

**Status:** Completed

## Scope

Milestone 2 turns durable inbound deliveries into a usable webmail projection:

1. Parse archived RFC 5322 messages asynchronously.
2. Preserve normalized messages, ordered and repeated headers, addresses, bodies,
   and attachment metadata.
3. Store extracted attachment bytes through a trusted object-store boundary.
4. Finalize mailbox entries into mailbox-scoped folders and conversations.
5. Provide mailbox-scoped PostgreSQL search.
6. Provide inbox, folder, conversation, search, and message views.
7. Support read, unread, starred, archive, restore, move, and trash actions.
8. Render untrusted HTML and attachment downloads through defensive web
   boundaries.

Composition and outbound submission remain Milestone 3. Security evaluation,
cloud ingress, external account synchronization, and optional client protocols
remain later milestones.

## Application Boundaries

Introduce `manifold_mail` with this dependency direction:

```text
manifold_mail
  -> manifold_core + manifold_data + manifold_storage

manifold_ingest
  -> manifold_core + manifold_data + manifold_accounts
     + manifold_storage + manifold_mail

manifold_web
  -> public APIs from manifold_accounts + manifold_ingest + manifold_mail
```

`manifold_mail` owns normalized mail content, attachments, folders, mailbox
entries, conversations, and search. It does not depend on transport schemas from
`manifold_ingest`; ingest passes a plain immutable source descriptor across the
boundary. Cross-application IDs remain scalar binary IDs rather than private
Ecto associations.

## Implementation Steps

1. Add the `manifold_mail` application, centralized projection migration, and
   attachment blob-store boundary.
   - Verify: dependency graph compiles without cycles and migrations apply to a
     fresh database.
2. Move mailbox-entry ownership into `manifold_mail` without changing the
   Milestone 1 SMTP acceptance transaction.
   - Verify: all transport recipient rows remain preserved and one entry is
     created per delivery/mailbox.
3. Add a bounded MIME parser and versioned normalized projection.
   - Verify: the fixture corpus covers plain text, alternatives, nested MIME,
     inline parts, attachments, repeated/folded headers, malformed messages,
     missing identifiers, 8-bit content, all normalized address kinds, and
     competing multipart branches.
   - Verify: increasing parser or sanitizer versions atomically rebuilds
     derived rows from the immutable raw source without resetting mailbox state.
4. Insert the first projection job in the same transaction that marks raw
   storage archived.
   - Verify: archival cannot commit without durable projection work, retries are
     idempotent, and reconciliation restores missing work.
5. Add per-mailbox folders, deterministic reference-based threading, and
   mailbox-scoped search.
   - Verify: data never crosses mailbox boundaries and no subject-only heuristic
     merges unrelated messages.
6. Add mailbox state commands.
   - Verify: read/unread, starred, archive, restore, move, and trash transitions
     are scoped, idempotent, and concurrency-safe.
7. Add the operational webmail interface.
   - Verify: `/` is the inbox; folder, conversation, message, and search
     navigation work; committed projection and state changes refresh open
     LiveViews.
8. Add isolated safe HTML rendering and defensive attachment download.
   - Verify: scripts, forms, active embeds, unsafe URLs, and remote images are
     blocked; storage keys are never public URLs; risky content is downloaded
     with `nosniff` and attachment disposition.
9. Run migration, test, compile, asset, browser, and real-delivery verification.
   - Verify: quality gates pass from a clean database and an SMTP delivery
     appears as a projected, searchable inbox conversation.

## Key Invariants

- Raw `.eml` remains immutable and authoritative; all Milestone 2 rows are
  rebuildable projections.
- Parsing runs only after raw archival is committed and never inside an SMTP
  session.
- Exactly one active projection exists per inbound delivery. Increasing parser
  or sanitizer versions atomically replaces its rebuildable derived rows in
  place while preserving mailbox state; stale or repeated jobs do not
  downgrade or duplicate messages, entries, threads, attachments, or events.
- A malformed message remains visible as a failed or fallback projection and
  never causes deletion of accepted raw data.
- MIME recursion, part count, decoded bytes, and attachment bytes are bounded.
- Repeated headers retain their order and untrusted filenames never become
  filesystem or object-store paths.
- Thread membership and every read/search/action query are scoped by mailbox.
- Remote images are blocked by default and untrusted message HTML is isolated
  from application CSS and script execution.
- PubSub refreshes committed state only; Oban remains the durable work trigger.

## Implemented Resource Limits

The default parser boundary enforces:

- Raw message bytes: 25 MiB.
- Header block bytes: 256 KiB.
- Header count: 1,000.
- MIME nesting depth: 20.
- MIME part count: 500.
- Total decoded bytes: 100 MiB.
- Individual attachment bytes: 50 MiB.
- Parse timeout: 30 seconds.
- Parser process heap: 16,000,000 words.

PostgreSQL full-text search indexes the subject, sender address, and the first
32,768 characters of normalized text. The complete normalized body and immutable
raw message remain available outside the bounded search projection.

## Crash Boundaries

Tests inject failure:

1. After attachment blob storage but before projection commit.
2. After projection commit but before ingest processing-state update.
3. After archival commit but before the projection worker runs.
4. During repeated projection and state actions.
5. During an atomic versioned projection rebuild.

Every boundary recovers through trusted IDs, database uniqueness, idempotent
object storage, and durable Oban retries.

## Completion Evidence

Completed on 2026-07-29 with:

- A fresh test database created entirely from centralized migrations.
- `mix format --check-formatted`.
- `mix compile --warnings-as-errors`.
- `mix test`: 140 tests, 0 failures.
- `mix assets.build` through Duskmoon Bundler.
- `mix app.tree --exclude hex --exclude mix`.
- `git diff --check`.
- A real TCP SMTP delivery projected through archival into searchable LiveView
  mailbox state.
- Desktop, tablet, and mobile browser checks with no document overflow, browser
  console errors, or failed asset requests.

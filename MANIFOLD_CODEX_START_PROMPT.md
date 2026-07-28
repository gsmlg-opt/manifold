# Codex Start Prompt — Bootstrap Manifold

You are a staff-level Elixir/OTP and Phoenix engineer. Start the implementation of **Manifold**, an Elixir-native inbound mail platform.

Manifold receives email for locally hosted domains, validates recipients during SMTP, durably stores accepted raw messages, processes them asynchronously, and presents them through Phoenix. Outbound delivery will later use a paid provider. Manifold must never implement direct outbound MX delivery in this milestone.

Work in the current repository. If the repository is empty, initialize it. Do not ask for clarification; make conservative decisions consistent with this prompt.

## Objective

Implement **Milestone 0 and Milestone 1 only**:

1. Reproducible umbrella repository.
2. PostgreSQL, Ecto, and Oban foundation.
3. Domain, mailbox, alias, and recipient-resolution model.
4. Inbound SMTP listener.
5. Durable spool bundle.
6. Atomic PostgreSQL acceptance transaction.
7. Transactional Oban archival job.
8. Local filesystem raw-message store.
9. Minimal Phoenix LiveView showing accepted inbound deliveries.
10. Tests for protocol, persistence, retry, and critical crash boundaries.

Do not build the full mail client, MIME parser, security engine, managed outbound provider, IMAP, POP3, JMAP, Gmail sync, Microsoft Graph sync, or cloud relay yet.

## Required technical stack

- Elixir/OTP.
- Phoenix umbrella application.
- Phoenix LiveView.
- `duskmoon_ui` for the initial UI where practical.
- PostgreSQL through Ecto and Postgrex.
- Oban for durable jobs.
- `gen_smtp` for the first SMTP protocol implementation, isolated behind Manifold modules.
- Jason for JSON.
- Nix flakes and devenv.
- Strict functional design. Use processes only for lifecycle, concurrency, scheduling, or resource ownership.
- No separate frontend SPA.
- No Docker-first development workflow; Nix/devenv is the primary local environment.

Pin compatible stable dependency versions in the repository rather than relying on globally installed tools.

## Initial umbrella applications

Create only the applications needed for the first vertical slice:

```text
apps/
├── manifold_core
├── manifold_data
├── manifold_accounts
├── manifold_storage
├── manifold_ingest
├── manifold_smtp
└── manifold_web
```

Preserve dependency direction and prohibit cycles. In the diagram below, `A -> B` means application `A` depends on application `B`:

```text
manifold_data
  -> manifold_core

manifold_storage
  -> manifold_core

manifold_accounts
  -> manifold_core + manifold_data

manifold_ingest
  -> manifold_core + manifold_data + manifold_accounts + manifold_storage

manifold_smtp
  -> manifold_core + manifold_accounts + manifold_ingest

manifold_web
  -> public APIs from manifold_accounts and manifold_ingest
```

`manifold_web` must not query another application's private schemas directly.

Future applications—`manifold_mail`, `manifold_security`, and `manifold_outbound`—should be documented but not scaffolded unless a concrete compile-time boundary requires them now.

## Application responsibilities

### `manifold_core`

Implement infrastructure-independent types and pure functions:

- Address parsing and normalization.
- Domain normalization.
- Shared error classification.
- Delivery-state transition validation.
- Clock and ID behaviours only where they materially improve deterministic tests.

Release 0.1 address policy:

- ASCII envelope addresses only.
- Do not advertise `SMTPUTF8`.
- Normalize domains to lowercase.
- Preserve original local parts for audit.
- Use a case-insensitive canonical local-part lookup policy.
- Support optional plus addressing.
- Return tagged tuples for expected failures.

Do not add a generic “utils” module.

### `manifold_data`

Own:

- `Manifold.Repo`.
- Ecto configuration.
- Centralized migrations.
- Oban supervision and configuration.
- Database health support.

Use `:binary_id` primary and foreign keys. Store timestamps in UTC.

### `manifold_accounts`

Implement:

- `Domain`.
- `Mailbox`.
- `Alias`.
- `AliasTarget`.
- Public account-management context functions.
- Public recipient resolver.

Required recipient resolution order:

1. Exact active mailbox.
2. Exact active alias.
3. Plus-address base mailbox or alias when enabled.
4. Unknown recipient.

An alias may target multiple mailboxes. A route is accepted only when at least one active mailbox target exists.

Expose a result equivalent to:

```elixir
{:ok,
 %Manifold.Accounts.Route{
   original_recipient: original,
   canonical_recipient: canonical,
   plus_tag: plus_tag,
   mailbox_ids: mailbox_ids
 }}
```

Unknown recipients return a classified error that `manifold_smtp` maps to `550 5.1.1`. Temporary database failures map to `451`, not `550`.

Do not implement catch-all routing in this milestone.

### `manifold_storage`

Implement two narrow boundaries:

1. Persistent spool.
2. Raw-message object store.

#### Persistent spool bundle

Use this layout:

```text
<spool-root>/
├── tmp/<ingest-id>.partial/
├── ready/<ingest-id>/
│   ├── manifest.json
│   └── raw.eml
├── failed/
└── quarantine/
```

The manifest is versioned JSON and contains at least:

- Version.
- Ingest ID.
- Received timestamp.
- Peer IP.
- HELO value.
- Envelope sender.
- Original recipients.
- Frozen resolved mailbox routes.
- Raw size.
- SHA-256 digest.

Write sequence:

1. Create private partial bundle.
2. Write `raw.eml`.
3. Write `manifest.json`.
4. Call filesystem sync for both files.
5. Sync directories where supported.
6. Atomically rename the bundle into `ready`.
7. Only then call the PostgreSQL acceptance transaction.

No sender-controlled value may be used in a path.

Do not serialize through one global GenServer. Per-delivery filesystem operations are independent.

#### Raw store behaviour

Define a behaviour supporting operations equivalent to:

- `put_from_path/3`
- `open` or streaming read
- `stat`
- `delete`

Implement a local filesystem adapter now. Structure the behaviour so an ESS/S3-compatible adapter can be added later without changing the ingest domain.

Generate object keys from trusted IDs, for example:

```text
raw/<domain-id>/<yyyy>/<mm>/<inbound-delivery-id>.eml
```

### `manifold_ingest`

Use transport terminology deliberately:

- `InboundDelivery`: one SMTP transaction and raw message.
- `DeliveryRecipient`: one resolved `RCPT TO` route.
- `MailboxEntry`: one delivery projected into one mailbox.
- `MessageEvent`: append-only operational/audit record; this is not event sourcing.

Implement initial schemas and migrations with fields equivalent to:

#### `inbound_deliveries`

- `id`
- `ingest_id`, unique
- `peer_ip`
- `helo`
- `envelope_from`
- `received_at`
- `raw_size`
- `raw_sha256`
- `spool_bundle_path`
- `raw_object_key`
- `raw_storage_state`
- `processing_state`
- `last_error`

#### `delivery_recipients`

- `inbound_delivery_id`
- `original_address`
- `canonical_address`
- `plus_tag`
- `mailbox_id`

#### `mailbox_entries`

- `mailbox_id`
- `inbound_delivery_id`
- `original_recipient`
- initial status

Prevent duplicate mailbox entries when multiple accepted recipient routes resolve to the same mailbox, while retaining every original `RCPT TO` record.

#### `message_events`

- `inbound_delivery_id`
- event type
- structured metadata
- timestamp

Implement one public acceptance function equivalent to:

```elixir
Manifold.Ingest.accept(spool_bundle, frozen_routes)
```

The acceptance function must use one `Ecto.Multi` to:

1. Insert `InboundDelivery`.
2. Insert all `DeliveryRecipient` rows.
3. Insert deduplicated `MailboxEntry` rows.
4. Insert an `accepted` event.
5. Insert the first Oban archival job in the same transaction.

Only a committed transaction is the logical acceptance point.

Implement an Oban archival job:

1. Load the delivery and verify state.
2. Copy/stream `raw.eml` to the configured raw store.
3. Verify at least size and expected SHA-256 where practical.
4. Update the delivery to archived and record `raw_object_key`.
5. Insert an `archived` event.
6. Remove the ready spool bundle only after the archived state commits.
7. Retry transient object-store errors.
8. Remain idempotent when executed repeatedly.

Implement a startup or scheduled spool reconciler with these rules:

- Ready bundle plus database row: ensure archival can resume.
- Archived database row plus remaining bundle: clean up after verification.
- Database row plus missing unarchived bundle: record and expose an operational failure.
- Ready bundle without database row: do not silently import it as accepted mail. Move it to a failed/orphan location after a retention policy.

The sender may retry after a connection failure and create a legitimate duplicate delivery. Do not hard-delete duplicates based on `Message-ID` or content hash.

### `manifold_smtp`

Run the development listener on configurable port `2525`; production configuration may use port `25`.

Implement through `gen_smtp`:

- `EHLO` and `HELO`.
- `MAIL FROM`.
- Multiple `RCPT TO`.
- `DATA`.
- `RSET`.
- `NOOP`.
- `QUIT`.
- STARTTLS configuration where supported.
- `SIZE`, `8BITMIME`, and `PIPELINING` where supported.
- No `AUTH`.
- No `SMTPUTF8`.

Keep the session callback thin:

1. Parse the envelope.
2. Resolve every recipient through `manifold_accounts`.
3. Freeze accepted routes for the current transaction.
4. Enforce maximum message size and recipient count.
5. Pass the raw DATA and frozen transport metadata to the spool.
6. Call `manifold_ingest` acceptance.
7. Return `250` only after the acceptance transaction commits.

Required response behavior:

```text
accepted                       -> 250 2.0.0 accepted as <ingest-id>
unknown recipient              -> 550 5.1.1
invalid address syntax         -> 501 5.1.3
temporary account/database err -> 451 4.3.0
spool/database accept failure  -> 451 4.3.0
insufficient spool capacity    -> 452 4.3.1
message too large              -> 552 5.3.4
```

Do not parse MIME, extract headers, scan attachments, call providers, or perform business notifications inside the SMTP process.

The initial `gen_smtp` path may buffer DATA. Set a conservative configurable maximum message size, defaulting to 25 MiB, and document the memory implication. Do not pretend this is streaming. Keep the adapter boundary clean so a streaming SMTP implementation can replace it later.

### `manifold_web`

Generate Phoenix authentication suitable for a single installation owner, without hardcoding global mailbox visibility into the data model.

Implement minimal LiveViews:

1. Domain list.
2. Mailbox list.
3. Alias list.
4. Inbound delivery list.
5. Inbound delivery detail showing:
   - Envelope sender.
   - Original recipients.
   - Resolved mailboxes.
   - Peer IP and HELO.
   - Received timestamp.
   - Raw size and SHA-256.
   - Spool/archive state.
   - Processing state.
   - Operational events.

Do not implement MIME body rendering yet. The first UI is an operational mailbox-ingress view.

Use public context APIs. Use PubSub only to refresh committed state; PubSub must not trigger durable work.

## Configuration

Support runtime configuration equivalent to:

```text
DATABASE_URL
MANIFOLD_SMTP_HOSTNAME
MANIFOLD_SMTP_BIND
MANIFOLD_SMTP_PORT
MANIFOLD_SMTP_MAX_MESSAGE_BYTES
MANIFOLD_SMTP_MAX_RECIPIENTS
MANIFOLD_SMTP_TLS_CERTFILE
MANIFOLD_SMTP_TLS_KEYFILE
MANIFOLD_SPOOL_DIR
MANIFOLD_SPOOL_MIN_FREE_BYTES
MANIFOLD_RAW_STORE_BACKEND
MANIFOLD_RAW_STORE_DIR
SECRET_KEY_BASE
PHX_HOST
PORT
```

Provide safe development defaults. Never commit credentials or private keys.

## Nix and repository tooling

Create:

- `flake.nix`
- `devenv.nix`
- `devenv.yaml`

The environment must provide:

- Erlang/OTP and Elixir.
- PostgreSQL development service.
- Node/frontend tooling required by Phoenix.
- Native build dependencies.
- Commands or scripts for setup, migration, tests, and starting Phoenix plus SMTP.

Add repository commands or Mix aliases for:

```text
mix setup
mix format --check-formatted
mix compile --warnings-as-errors
mix test
```

Add a CI workflow that runs the deterministic quality checks with PostgreSQL available. Do not require live Internet services in tests.

## Testing requirements

Implement tests before declaring the milestone complete.

### Account tests

- Domain normalization.
- Mailbox lookup.
- Alias to one mailbox.
- Alias to multiple mailboxes.
- Disabled mailbox rejection.
- Plus-address resolution.
- Unknown recipient classification.
- Resolver determinism.

### Spool tests

- Bundle creation.
- Manifest round trip.
- SHA-256 and byte count.
- Atomic ready transition.
- No untrusted path components.
- Partial-bundle cleanup behavior.
- Ready orphan classification.

### Ingest tests

- Acceptance creates all rows.
- Multiple routes create all transport recipient records.
- Duplicate routes to one mailbox create one mailbox entry.
- Oban archival job is inserted transactionally.
- Acceptance transaction failure does not report success.
- Repeated archival job is idempotent.
- Object-store failure leaves the ready bundle and retries.
- Successful archive records the object key before cleanup.

### SMTP integration tests

Use a real TCP connection to the test listener where practical:

- Unknown recipient returns `550` at `RCPT TO`.
- Known recipient accepts DATA.
- Successful transaction creates a durable delivery.
- Multiple recipients are preserved.
- Oversized message is rejected.
- Temporary recipient resolver failure maps to `451`.
- Acceptance failure never returns `250`.
- No `AUTH` or `SMTPUTF8` advertisement.

### Crash-boundary tests

At minimum, create explicit tests or fault-injection seams for:

1. Failure before ready rename.
2. Failure after ready rename but before database commit.
3. Failure after database commit but before archival.
4. Failure after raw-store copy but before archived-state update.
5. Failure after archived-state update but before spool cleanup.

Document expected recovery for every boundary.

### Web tests

- Authenticated owner can view domain/mailbox/delivery lists.
- Delivery details are loaded through context APIs.
- Unauthenticated access is rejected.
- Raw paths and object-store keys are not exposed as direct public URLs.

## Documentation

Create:

```text
README.md
docs/DESIGN.md
docs/adr/0001-inbound-first.md
docs/adr/0002-durable-spool-before-smtp-ack.md
docs/adr/0003-postgresql-and-oban.md
docs/adr/0004-managed-outbound-only.md
docs/adr/0005-raw-message-source-of-truth.md
```

The README must explain:

- What Manifold is.
- What the first milestone implements.
- What is intentionally out of scope.
- How to enter the devenv shell.
- How to initialize PostgreSQL and run migrations.
- How to create a development domain and mailbox.
- How to run Phoenix and the SMTP listener.
- How to run all tests.
- The durability semantics of SMTP `250`.

## Engineering constraints

- Prefer pure functions and tagged tuples.
- No OOP-style service objects.
- No GenServer around stateless contexts.
- No process dictionary for business state.
- No global mutable in-memory source of truth.
- No direct schema access across application boundaries.
- No broad rescue that converts programmer errors into SMTP success.
- No background work triggered only by PubSub.
- No hard deletion of possible duplicate deliveries.
- No direct Internet MX delivery.
- No MIME parsing in the SMTP session.
- No TODO placeholder in the acceptance path.
- Keep modules small and named by domain responsibility.
- Add typespecs to public APIs.
- Emit Telemetry for SMTP transactions, spool writes, acceptance, and archival.
- Do not log message bodies, credentials, or attachment content.

## Definition of done

The milestone is complete only when all of the following are true:

1. The Nix/devenv environment boots reproducibly.
2. PostgreSQL migrations create the required schema.
3. An administrator or seed can create a domain and mailbox.
4. A real SMTP transaction to port 2525 rejects unknown recipients at `RCPT TO`.
5. A valid delivery receives `250` only after durable spool and committed acceptance state.
6. The accepted raw `.eml` is archived by an Oban job.
7. Restarting the application resumes committed archival work.
8. The minimal LiveView shows the accepted delivery and lifecycle events.
9. The required unit, integration, and crash-boundary tests pass.
10. `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `mix test` pass.
11. The documentation accurately describes implemented behavior and known limits.

Begin by inspecting the repository, then write a short implementation plan into `docs/IMPLEMENTATION_PLAN.md`. Proceed immediately with implementation. Keep the plan aligned with the vertical slice; do not expand scope into MIME parsing, outbound delivery, client protocols, or cloud relay. At completion, report:

- The implemented architecture.
- Important invariants.
- Files and applications added.
- Commands executed.
- Test results.
- Any concrete remaining risks in Milestone 1.

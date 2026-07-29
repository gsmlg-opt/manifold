# Manifold Milestone 3 Implementation Plan

**Status:** Completed

## Scope

Milestone 3 adds managed outbound delivery to the local webmail client:

1. Compose and persist drafts.
2. Prepare reply, reply-all, and forward drafts from projected inbound mail.
3. Queue a frozen draft and its first Oban submission job atomically.
4. Submit through a provider behaviour and the first Resend HTTPS adapter.
5. Track provider acceptance separately from final delivery.
6. Verify, normalize, and persist Resend webhooks.
7. Expose sent mail and provider delivery state in Phoenix LiveView.

Direct recipient-MX delivery, an outbound SMTP relay, provider account
provisioning, marketing/bulk mail, and Gmail or Microsoft Graph synchronization
remain out of scope.

## Application Boundaries

Add `manifold_outbound` with this dependency direction:

```text
manifold_outbound
  -> manifold_core + manifold_data + manifold_accounts + manifold_mail

manifold_web
  -> public APIs from manifold_accounts + manifold_ingest
     + manifold_mail + manifold_outbound
```

`manifold_outbound` owns drafts, outbound recipients, provider submissions,
provider events, state transitions, submission jobs, and provider adapters. It
uses public account and mail APIs for sender validation and reply source data.
No other application queries its private schemas.

## Delivery Model

The initial schemas are:

- `OutboundMessage`: immutable after queueing; owns sender snapshot, subject,
  text body, composition kind, source-message references, submission lifecycle
  state, timestamps, and classified last error.
- `OutboundRecipient`: ordered `to`, `cc`, and `bcc` snapshots with independent
  delivery state.
- `ProviderSubmission`: one logical mutable submission with stable request
  digest, idempotency key, attempt metadata, safe retry window, and provider
  identifiers.
- `ProviderEvent`: append-only, provider-scoped webhook event with a unique
  provider event ID and retained namespaced metadata.
- `OutboundEvent`: append-only local lifecycle record.

Initial message states are:

```text
draft
  -> queued
  -> submitting
  -> accepted_by_provider

queued | submitting -> failed | submission_uncertain
```

Each recipient has an independent provider-delivery state:

```text
pending
  -> sent
  -> delayed | delivered | bounced | failed | suppressed

delivered -> complained
```

Provider acceptance is not final delivery. Recipient outcomes may diverge.
Replayed or out-of-order provider events must not regress recipient state.

## Implementation Steps

1. Add the application, migration, schemas, state transition validator, and
   public context.
   - Verify: fresh migrations apply, IDs are binary UUIDs, and database
     constraints reject invalid states and duplicate idempotency keys.
2. Add sender-identity and reply-source public views to accounts and mail.
   - Verify: inactive mailboxes or domains cannot send; reply-all excludes the
     local sender and deterministically deduplicates recipients.
3. Implement draft creation, update, list, delete, and composition preparation.
   - Verify: draft edits are optimistic, address validation is classified, and
     queued messages cannot be mutated or deleted.
4. Implement transactional queueing and the outbound Oban worker.
   - Verify: queueing inserts exactly one job in the same transaction; retries
     reuse the stable idempotency key; transient failures retry; terminal
     failures persist `failed`.
5. Implement the provider behaviour and Resend adapter.
   - Verify: request payloads and headers are deterministic; API keys never
     enter job args, database rows, logs, or telemetry; HTTP status classes map
     to retryable or terminal errors.
6. Implement raw-body Resend webhook verification and event normalization.
   - Verify: Svix HMAC-SHA256 signatures use the raw body, enforce timestamp
     tolerance, compare in constant time, reject missing or invalid headers,
     and deduplicate by `svix-id`.
7. Implement provider event application and pending-event reconciliation.
   - Verify: delivered, bounced, complained, suppressed, and failed events
     transition messages monotonically; an event received before the provider
     response is attached after submission commits.
8. Add compose, draft, reply, reply-all, forward, and sent-mail LiveViews.
   - Verify: all workflows use public contexts, preserve unsent drafts, expose
     provider state without exposing secrets, and work on desktop and mobile.
9. Run fresh migration, full tests, compile, assets, browser, and dependency
   graph verification.

## Key Invariants

- Manifold never resolves recipient MX records or opens outbound SMTP sessions.
- A message is editable only in `draft`; queueing freezes sender, recipients,
  subject, body, and source references.
- Draft-to-queue state and the first Oban job commit atomically.
- Provider credentials are runtime-only and are fetched by the adapter when a
  job executes.
- Queueing creates one logical provider submission; every retry reuses its
  request digest and Manifold idempotency key.
- An ambiguous submission older than the provider's 24-hour idempotency window
  becomes `submission_uncertain` and is not resent automatically.
- Resend's provider ID is persisted before a message is shown as accepted.
- Provider events are authenticated before JSON decoding or persistence.
- Provider event IDs are unique within the provider namespace.
- Webhooks and submission retries are idempotent and state transitions are
  monotonic.
- PubSub only refreshes committed state; it never initiates submission.

## Initial Limits

- ASCII envelope addresses, consistent with Release 0.1 inbound policy.
- At most 50 recipients per outbound message, matching the first provider
  adapter.
- Subject length: 998 bytes.
- Text body size: 10 MiB.
- Plain-text composition only in this milestone; provider HTML is omitted
  rather than rendering unsanitized user input.
- Outbound attachment upload is deferred; inbound attachment storage and
  download remain available.

## Crash Boundaries

Tests inject or explicitly cover:

1. Failure before the queue transaction commits.
2. Failure after queue commit but before the worker starts.
3. Transient provider failure before acceptance.
4. Provider acceptance followed by failure before local state commit.
5. Provider webhook arrival before provider response persistence.
6. Failure after provider-event insertion but before recipient-state update.
7. Replayed and out-of-order provider events.

Recovery relies on PostgreSQL transactions, Oban durability, stable idempotency
keys, provider-scoped event uniqueness, and reconciliation of pending events.

## Verification

- Fresh PostgreSQL schema migration completed through
  `20260729000300_create_outbound_delivery`.
- `mix format --check-formatted` passed.
- `mix compile --warnings-as-errors` passed.
- `mix test` passed with 195 tests and no failures.
- `mix assets.build` passed.
- Desktop and 390 px mobile compose/sent views were exercised in a real browser
  with no document overflow or hidden primary actions.

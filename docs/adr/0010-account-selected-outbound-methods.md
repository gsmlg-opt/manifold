# ADR 0010: Account-Selected Outbound Methods

- **Status:** Accepted and implemented
- **Date:** 2026-08-11
- **Supersedes:** ADR 0007 only where it deferred provider-backed outbound sending

## Context

Manifold accounts can receive through local delivery or external connectors, but
outbound mail previously used only the installation-wide legacy Resend adapter.
That does not preserve a Gmail user's native Sent behavior and cannot represent
different delivery identities for different Manifold accounts. SMTP submission
settings already had a persistent model but were not part of the outbound queue
contract.

Gmail receive and send grants belong to one Google identity and may be granted at
different times. Duplicating OAuth records would allow their token generations,
reconnect state, or permanent subject binding to diverge. Gmail API and SMTP
submission are not idempotent after the remote server may have accepted bytes, so
an interrupted request cannot be retried as though no side effect occurred.

## Decision

Each Manifold account selects one enabled send method. Different Manifold
accounts may bind different Gmail identities, but a Gmail identity is permanently
bound to only one Manifold account and its exact canonical email address must
match that account. A queued message snapshots the selected method and provider;
later settings changes never reroute it.

Gmail receive and send methods share one encrypted
`connector_oauth_authorizations` row. OAuth starts with a `receive` or `send`
purpose and incrementally requests the union of the already granted Gmail scopes
and the new purpose scope. Receive uses
`https://www.googleapis.com/auth/gmail.readonly`; send uses
`https://www.googleapis.com/auth/gmail.send`. Token refresh and
reconnect-required state are serialized on the shared authorization and apply to
both directions.

`manifold_outbound` renders deterministic text-only RFC messages, including
`Message-ID`, `Date`, `In-Reply-To`, and `References` where applicable. It checks
the rendered hash before credential checkout or provider I/O. Gmail submissions
use the Gmail API and appear through Gmail's normal Sent behavior. SMTP methods
submit through the account's configured authenticated relay. HTML composition,
attachments, sender aliases, and Microsoft Graph send are deferred.

Before provider I/O, the queue records a `submitting` attempt. Gmail and SMTP have
no automatic resend after an interruption or an ambiguous provider response. The
message becomes `submission_uncertain`; an operator or user must reconcile it
before taking another action. This favors duplicate prevention over automatic
delivery recovery.

The existing Resend request and webhook path remains valid for messages already
queued with the legacy `provider = 'resend'` shape. New account-selected Gmail and
SMTP submissions always retain their send-method snapshot. Manifold still never
delivers directly to recipient MX servers.

## Operational Cutover

This is a non-rolling database and application cutover. Operators must fully
drain and stop old Phoenix instances, connector workers, and Oban workers before
running migration `20260811000500_add_shared_gmail_authorizations.exs`; old and
new code must not run concurrently. Start only the new release after all three
2026-08-11 migrations complete.

Migration `00500` moves legacy Gmail token material into the shared authorization
and deletes the migrated legacy credential. Its down migration performs lossless
restoration preflights and refuses rollback when the original receive row is
missing, restoration would conflict, token material cannot satisfy the legacy
shape, or Gmail send methods exist. Migration `00600` refuses rollback when an
authorization event cannot map to exactly one legacy receive method. Migration
`00700` refuses rollback while any Gmail or SMTP provider submission exists.
Resolve those conditions deliberately; do not bypass the guards.

## Consequences

### Positive

- Each account submits through its explicitly selected identity.
- Gmail receive and send share token rotation, reconnect state, and permanent
  subject binding.
- Queued messages are stable across method changes.
- Ambiguous acceptance cannot cause an automatic duplicate.
- Legacy Resend lifecycle and webhook records remain readable and actionable.

### Negative

- Gmail OAuth configuration and scope verification add operator work.
- An uncertain submission requires manual reconciliation.
- The migration cannot be deployed safely as a rolling upgrade.
- Text-only messages omit HTML and attachments until later milestones.

## Rejected Alternatives

### Separate Gmail authorizations for receive and send

Rejected because tokens, scope upgrades, reconnect state, and durable Google
subject binding could diverge.

### Automatically retry Gmail or SMTP after an interrupted request

Rejected because the remote provider may already have accepted the message.

### Choose a method when the worker runs

Rejected because a settings change could silently reroute an already queued
message or change its sender identity.

### Replace legacy Resend rows during migration

Rejected because those rows describe already queued or submitted lifecycle state
and remain valid compatibility data.

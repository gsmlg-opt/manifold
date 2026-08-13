# ADR 0011: Microsoft Graph Send and Authoritative Sent

- **Status:** Accepted
- **Date:** 2026-08-12
- **Extends:** ADR 0007 and ADR 0010

## Context

Microsoft 365 accounts already synchronize mail through a delegated, read-only
Graph connector. Users also need to send through the same Microsoft identity,
without broadening receive synchronization into remote mailbox mutation or
inventing a second OAuth credential lifecycle.

Graph exposes both draft-based workflows and direct MIME submission. Draft
creation would require `Mail.ReadWrite`, add draft cleanup and reconciliation,
and couple outbound delivery to remote mailbox mutation. Direct
`POST /me/sendMail` accepts MIME with `Mail.Send`, but a successful response has
no durable provider message identifier and an interrupted request may have been
accepted.

The local Sent mailbox and the outbound submission history have different
semantics. Graph Sent Items is provider mailbox state discovered by polling;
outbound state records Manifold's queue and acceptance decisions immediately.

## Decision

Microsoft receive and send methods share one encrypted
`connector_oauth_authorizations` row. Receive retains delegated `Mail.Read` and
does not mutate the mailbox. Send incrementally requests delegated `Mail.Send`;
the durable scope union also retains `offline_access`, while identity validation
uses `User.Read`. Existing receive-only accounts grant `Mail.Send` only when a
send method is added.

`manifold_outbound` renders the exact RFC message at queue time and stores the
MIME payload, render version, sender, method, provider `Message-ID`, and SHA-256
as an immutable provider-submission snapshot. That persisted byte string is the
retry identity boundary. A worker verifies the snapshot and sends
`Base.encode64(exact_mime)` as `text/plain` to `POST /me/sendMail`; it never
re-renders from mutable draft fields.

Only a bodyless HTTP `202 Accepted` is success. It means Graph accepted the
submission request, not that a recipient received the message. Direct
`sendMail` supplies no provider message ID; bounded Graph request IDs may be
retained only as diagnostic provider metadata.

Graph Sent Items imported through the normal folder/message delta lanes is the
authoritative Sent copy. Every mailbox has one local system Sent folder, and
well-known folder IDs classify localized Graph folders. The projected Sent view
contains imported provider messages. A separate Send activity view contains
queued, accepted, failed, retryable, and uncertain outbound lifecycle records.
The two models are intentionally not merged or deduplicated.

Retry rules follow provable transmission state:

- HTTP `429` and explicit pre-transmission failures are retryable.
- Definite request/auth/policy rejections are terminal failures.
- Graph `5xx`, malformed success responses, post-transmission errors, and other
  ambiguous transport failures are terminal uncertainty.
- Uncertain submissions are never resent automatically.

The implementation adds no Graph webhook, optimistic local Sent copy, draft
creation, direct record link, or automatic uncertain resend. Polling remains the
only way the authoritative Sent copy converges when Receive is enabled.

## Consequences

### Positive

- Receive remains least-privilege and read-only while outbound has its own
  independently granted capability.
- Receive and send share token rotation, subject binding, address validation,
  reconnect state, and active-account fences.
- Exact persisted MIME prevents retries from changing bytes or sender identity.
- Local Sent reflects provider mailbox truth, while Send activity is available
  immediately after queueing or provider acceptance.
- Ambiguous failures cannot cause an automatic duplicate.

### Negative

- A send-only account has Send activity but no projected Sent copy.
- With Receive enabled, Sent projection is delayed until normal or manual Graph
  polling imports the provider copy.
- A `202` cannot provide recipient-delivery proof or a provider message link.
- Operators and users must reconcile uncertain submissions manually.

## Rejected Alternatives

### Create and send Graph drafts

Rejected because it requires `Mail.ReadWrite`, remote mutation, and a draft
reconciliation/cleanup lifecycle unrelated to receive synchronization.

### Optimistically copy accepted MIME into local Sent

Rejected because the provider copy is authoritative and an optimistic copy
would require a later identity/deduplication merge.

### Retry every transport or 5xx failure

Rejected because Graph may already have accepted the bytes, so an automatic
retry could produce a duplicate message.

### Link Send activity directly to a Graph record

Rejected because direct MIME `sendMail` returns no provider message ID and the
later Sent Items delta record has an independent identity.

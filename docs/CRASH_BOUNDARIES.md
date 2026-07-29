# Crash Boundaries

1. Failure before ready rename leaves only a partial bundle. The startup reconciler removes expired partials; no database acceptance exists.
2. Failure after ready rename but before database commit leaves a ready orphan. Recovery does not import it as accepted mail; after retention it atomically moves to `failed/`.
3. Failure after database commit but before archival leaves a committed delivery, ready bundle, and transactional Oban job. Oban or startup reconciliation resumes archival.
4. Failure after raw-store copy but before archived-state update leaves a copied object and spooled database state. Retry verifies the object, atomically replaces it when incomplete, and commits archive state once.
5. Failure after archived-state update but before spool cleanup leaves archived database state and a remaining ready bundle. Recovery verifies size and SHA-256 in the raw store before removing the bundle.
6. Failure after attachment blob storage but before projection commit leaves only
   content-addressed blobs. Retry verifies and reuses those blobs, then commits
   message, attachment, folder, thread, and mailbox-entry projection rows once.
7. Failure after projection commit but before ingest processing-state update
   leaves a complete idempotent mail projection and a delivery in `parsing`.
   The Oban retry reloads the existing projection and commits `processed` plus
   the lifecycle event without duplicating projection rows.
8. Failure after archival commit but before projection execution leaves an
   archived delivery and a transactional `ProjectInboundMail` job. Oban executes
   it after restart; reconciliation inserts missing active work for archived or
   parsing deliveries.
9. A permanent projection failure, such as an archived raw object whose size or
   SHA-256 no longer matches acceptance metadata, commits `failed` processing
   state and a `projection_failed` event. Oban cancels that job, and reconciliation
   does not recreate it until an operator repairs the source and explicitly
   retries processing.
10. Failure after versioned attachment storage but before a projection rebuild
    transaction leaves the previous active projection unchanged. Retry reparses
    the immutable raw source, replaces message-derived rows in one transaction,
    and preserves mailbox folder, read, starred, and thread identity.
11. Failure before the outbound queue transaction commits leaves the message as
    an editable draft. The provider submission, local event, and Oban job roll
    back with the state change.
12. Failure after the outbound queue commits but before worker execution leaves
    a frozen queued message, one logical provider submission, and a committed
    Oban job. Oban resumes submission after restart.
13. A transient provider or transport failure returns the message to `queued`
    and preserves the ready submission. Retries reuse the same request content
    and idempotency key; provider `Retry-After` is mapped to an Oban snooze.
14. Failure after provider acceptance but before the local acceptance
    transaction commits leaves the message in `submitting`. Retry uses the same
    provider idempotency key within its 24-hour safety window.
15. A submission still ambiguous when its provider idempotency window expires
    becomes `submission_uncertain`. Manifold does not automatically resend it.
16. A valid webhook received before the provider message ID commits is retained
    as unmatched. The provider-acceptance transaction reconciles and applies it;
    duplicate and out-of-order events do not regress recipient state.
17. SMTP acceptance creates mailbox entries quarantined. A crash before
    security evaluation cannot make pending mail visible.
18. Failure before the archive transaction commits rolls back the security job
    together with archive state. The existing archive job retries from the
    ready spool bundle.
19. Failure after archive commit but before security worker execution leaves a
    verified raw object and a transactional security job. Oban or reconciliation
    resumes evaluation after restart.
20. A transient adapter failure commits no successful assessment and leaves all
    mailbox entries quarantined. Oban retries the same evaluation version.
21. Failure after assessment persistence but before policy application leaves
    `policy_applied = false` and the mailbox projection hidden. Retry applies the
    stored decision without duplicating the assessment.
22. Failure after an allow decision updates mailbox visibility but before the
    assessment finalization leaves the persisted allow decision available for
    retry. Retry marks the same policy applied; it does not rerun adapters.
23. Failure during manual release before the release audit commit can clear
    visibility only after an explicit operator decision. Repeating release
    commits one effective `released` event.
24. SMTP session crashes release monitored per-peer connection leases. Admission
    counters are deliberately ephemeral and reset on SMTP application restart;
    no durable mail state depends on them.
25. Edge ready rename before the edge database commit returns no SMTP `250`.
    Reconciliation retains the orphan and moves it to `failed/` only after the
    configured retention interval.
26. Edge database commit before the SMTP response may cause a legitimate sender
    retry. Each SMTP transaction remains a distinct accepted edge delivery.
27. Interrupted local raw transfer creates no local ready bundle, provenance
    row, or edge acknowledgement. The Oban pull retries the same edge ID.
28. Local ready rename before local acceptance leaves a deterministic ready
    bundle. Retry loads and verifies that bundle before reattempting the atomic
    local acceptance, without downloading another copy. The edge retains its
    copy, and the ready bundle alone is never treated as logical acceptance.
29. Local acceptance and edge provenance commit in one transaction. A crash
    before acknowledgement is repaired by lookup of the existing receipt,
    followed by an idempotent acknowledgement.
30. Edge acknowledgement commit before spool cleanup leaves an acknowledged
    tombstone and bundle. Edge reconciliation verifies size and SHA-256 before
    removing the remaining bundle.
31. Snapshot installation failure before activation leaves the previous
    snapshot active. Missing or expired snapshots cause temporary SMTP
    rejection; stale or conflicting revisions are never activated.
32. A permanent local integrity or provenance failure is reported through the
    signed edge API. The edge marks that delivery failed, retains its raw bundle
    for operator recovery, and later pending deliveries continue to synchronize.
33. A transient filesystem status error does not change a ready edge delivery
    to failed. A truly missing bundle records `missing_spool`; if its complete,
    verified bundle reappears, reconciliation records `spool_restored` and
    returns it to ready.
34. A crash during acknowledged spool deletion occurs only after an atomic
    rename into a deterministic cleanup tombstone. Reconciliation can remove
    the remaining tombstone without requiring files already deleted.
35. A request signed with a future timestamp retains its nonce until after the
    complete signature validity window, so nonce pruning cannot reopen replay.
36. Signed edge requests are bound to the received Host authority, never follow
    redirects, and return authenticated metadata and raw content with
    `Cache-Control: no-store, private`.
37. Failure after an OAuth transaction commits but before redirecting to the
    provider leaves an unused, hashed-state row. It grants no provider access
    and becomes unusable after its expiry time.
38. OAuth state consumption commits before token exchange. If exchange or local
    authorization persistence fails, the state cannot be replayed; the user
    must start a new authorization. Any provider-side grant is harmless to
    Manifold until encrypted credentials commit locally.
39. Account, encrypted credential, initial cursor, connector event, and first
    sync job are one PostgreSQL transaction. A failure before commit exposes no
    partially connected local account.
40. Refresh-token rotation commits before processing the next provider page.
    If page processing later fails, retry decrypts and reuses the newest
    committed token envelope.
41. Failure during provider raw fetch creates no spool bundle and advances no
    cursor. The current sync job retries or stops according to the provider
    error classification.
42. Failure before a provider-import ready rename leaves only a partial bundle.
    Existing spool partial cleanup semantics apply; no external ingress
    identity or local acceptance exists.
43. Failure after the deterministic ready rename but before provider acceptance
    commit leaves a ready bundle and no logical acceptance. Retrying the same
    provider identity verifies and reuses that bundle before reattempting the
    acceptance transaction.
44. Provider acceptance commits the inbound delivery, mailbox entry, accepted
    event, archive job, and external-ingress identity atomically. Failure after
    that commit but before connector-message mapping leaves a recoverable
    receipt; retry finds the identity and maps it without importing a second
    delivery.
45. Failure after connector-message mapping but before cursor checkpoint leaves
    the provider cursor unchanged. Retry idempotently updates the same mapping
    and reuses the accepted delivery.
46. Remote-state work is inserted with an imported mapping. If it executes
    before normal mail projection, it snoozes on `projection_pending`; after
    projection it applies folder, read, starred, and deleted state
    idempotently.
47. Failure after cursor checkpoint but before the current Oban job returns
    leaves the next cursor position durable. Retrying the same job selects the
    next incomplete lane; it does not repeat a committed cursor position as new
    mail.
48. Gmail history expiry resets the mailbox lane to a non-destructive initial
    scan. Existing provider identities prevent duplicate local deliveries.
49. Microsoft Graph delta expiry resets only the affected folder or
    folder-discovery lane. Opaque continuation URLs are followed only when they
    retain the configured HTTPS authority.
50. A Microsoft folder membership removal does not delete local mail. The
    connector waits for a corresponding message state from another folder;
    local immutable raw data remains retained if observations arrive in either
    order.
51. A provider deletion updates remote state and moves an existing local
    projection to trash. It never deletes the archived raw object or accepted
    inbound delivery.
52. Disconnect deletes encrypted credentials and disables synchronization.
    Already queued sync jobs fail closed when they reload the disconnected
    account; imported local mail remains available.

53. Failure after a sync job finishes or disappears while its account remains
    eligible is repaired by the five-minute `PollAccounts` cron job. It inserts
    at most one incomplete sync job per account.

Migration `20260729000700` is intentionally irreversible after provider imports.
Provider deliveries have no SMTP peer IP, so downgrading cannot restore the
previous non-null transport column without fabricating audit data.

A provider message returning `404` between listing and raw fetch is normalized
into an idempotent remote tombstone. The cursor may advance after that
observation is durable, while any existing local raw object remains retained.

A database row whose unarchived bundle is missing is marked `missing_spool` with an
operational event. If that trusted ready bundle later reappears, reconciliation
records `spool_restored`, returns the delivery to `spooled`, and resumes archival.

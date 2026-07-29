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

A database row whose unarchived bundle is missing is marked `missing_spool` with an
operational event. If that trusted ready bundle later reappears, reconciliation
records `spool_restored`, returns the delivery to `spooled`, and resumes archival.

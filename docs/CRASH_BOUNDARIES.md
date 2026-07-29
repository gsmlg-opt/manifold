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

A database row whose unarchived bundle is missing is marked `missing_spool` with an
operational event. If that trusted ready bundle later reappears, reconciliation
records `spool_restored`, returns the delivery to `spooled`, and resumes archival.

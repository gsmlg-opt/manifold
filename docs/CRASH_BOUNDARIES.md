# Crash Boundaries

1. Failure before ready rename leaves only a partial bundle. The startup reconciler removes expired partials; no database acceptance exists.
2. Failure after ready rename but before database commit leaves a ready orphan. Recovery does not import it as accepted mail; after retention it atomically moves to `failed/`.
3. Failure after database commit but before archival leaves a committed delivery, ready bundle, and transactional Oban job. Oban or startup reconciliation resumes archival.
4. Failure after raw-store copy but before archived-state update leaves a copied object and spooled database state. Retry verifies the object, atomically replaces it when incomplete, and commits archive state once.
5. Failure after archived-state update but before spool cleanup leaves archived database state and a remaining ready bundle. Recovery verifies size and SHA-256 in the raw store before removing the bundle.

A database row whose unarchived bundle is missing is marked `missing_spool` with an
operational event. If that trusted ready bundle later reappears, reconciliation
records `spool_restored`, returns the delivery to `spooled`, and resumes archival.

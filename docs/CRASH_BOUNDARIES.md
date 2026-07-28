# Crash Boundaries

1. Failure before ready rename leaves only a partial bundle. Recovery cleans old partials; no database acceptance exists.
2. Failure after ready rename but before database commit leaves a ready orphan. Recovery does not import it as accepted mail; after retention it moves to `failed/`.
3. Failure after database commit but before archival leaves a committed delivery, ready bundle, and Oban job. Recovery retries archival.
4. Failure after raw-store copy but before archived-state update leaves a copied object and spooled database state. Retry verifies or rewrites the object and commits archive state.
5. Failure after archived-state update but before spool cleanup leaves archived database state and a remaining ready bundle. Recovery removes the bundle after verification.

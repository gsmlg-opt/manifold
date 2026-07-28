# ADR 0002: Durable Spool Before SMTP Ack

SMTP `250` is a durability promise. Manifold writes `raw.eml` and `manifest.json`, syncs files and directories where supported, atomically renames the bundle into `ready/`, and then commits PostgreSQL acceptance state with the initial Oban job.

If any step fails before commit, SMTP returns a transient failure instead of success.

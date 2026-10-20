# Deployment documentation

- Date: 2026-10-13.
- Status: done.
- Scope: operator documentation only; no application/config/schema changes or
  deployment/publication operations.

## Ownership

- `docs/DEPLOYMENT.md`: main and optional edge installation, inline Compose and
  Caddy examples, release migrations, persistent data, upgrades and recovery.
- `docs/README.md` and root `README.md`: operator entry points.
- `config/runtime.exs`, `Dockerfile` and root `mix.exs`: runtime, permissions,
  image behavior and release closure contracts that examples must follow.
- `manifold_data`: main migrations and Styx; `manifold_edge`: separate Repo,
  migration helper and signed API; `manifold_smtp`: edge-only SMTP listener.
- `manifold_storage`: local spool/raw/blob persistence; `manifold_connectors`:
  stable encryption key, database-backed provider settings and activity logs.

## Constraints

Pin examples to a reviewed version, and distinguish tag/ABI assumptions from
target-host acceptance. Keep secrets and actual deployment files outside the
repository. Main and API have trusted-instance access; HTTPS alone adds no login.
Main has no inbound SMTP and no `Manifold.Release.migrate/0` helper. An installed
release needs an explicit migration before application startup.

Docker runs as UID/GID 1000:1000; persist all main stores and Connector logs with
writable mounts. Edge persists its separate database and spool. Preserve signed
API path/body/Host, distinguish listener probes from authenticated readiness,
and keep encryption keys and source identity stable across upgrades/restores.
Do not add undocumented environment switches, automatic credential import,
rolling OAuth cutovers or unguarded schema rollback instructions.

For the 2026-10-21 engine cutover, follow the
[Styx migration record](styx-migration.md) and its deployment runbook.

## Validation

2026-10-13: PASS for local Markdown targets/anchors (40 links across 5 files),
whitespace, 10 shell blocks (`sh -n`), two Compose configurations with disposable
placeholder env files and two Caddy adaptations without starting services.
These checks do not prove a target deployment or real provider integration.
Application tests are unnecessary for prose-only
changes. Keep runtime/provider acceptance linked to its dated owning record.

## Follow-ups

Operator-specific DNS/HTTPS/SMTP, credentialed provider writes and complete
backup/restore acceptance remain tracked in `docs/PROGRESS.md`.

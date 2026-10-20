# Styx background-job migration

## Feature

- **Name**: Replace Oban with Styx and preserve durable jobs.
- **Date**: 2026-10-21.
- **Owner/Requestor**: Manifold maintainers.
- **Status**: done; implementation, application regression and disposable-database
  upgrade/restart/rollback verification complete. Deployment is separate.

## Scope

- **Apps touched**: `manifold_data`, `manifold_connectors`, `manifold_ingest`,
  `manifold_outbound`, `manifold_cloud`, `manifold_account_lifecycle`,
  `manifold_security`, `manifold_web`; test references in `manifold_contacts`.
- **Files changed**: owning apps' dependencies, job modules and tests; shared
  configuration, initial/cutover migrations, lockfile and current operator docs.
- **Reason for change**: use the maintained `gsmlg-dev/styx` fork while retaining
  existing job identities and application behavior.

## Module ownership

- `manifold_data`: `Styx` supervision/configuration, `Manifold.Data.StyxJobs`,
  fresh-install schema and transactional legacy-storage migration.
- `manifold_connectors`: sync workers, remote-state uniqueness/cancellation and
  account authorization enqueueing.
- `manifold_ingest`: archive, projection, security and reconciliation workers.
- `manifold_outbound`: submission workers, provider-attempt accounting and snooze.
- `manifold_cloud`: delivery polling and route publication workers.
- `manifold_account_lifecycle`: atomic purge enqueueing and job cleanup.
- `manifold_web`: `/jobs` queries/labels and `[:styx, :job, ...]` sync telemetry.
- `manifold_security`: explicit dependency declaration.
- `manifold_contacts`: test references only.
- `manifold_accounts`, `manifold_api`, `manifold_smtp`, `manifold_storage`,
  `manifold_edge`, `manifold_core`: no implementation changes; Core retains the
  runtime `tzdata` dependency shared by Main and Edge.

## Design and data impact

- **Database/migration impact**: the historical `AddOban` migration keeps its
  timestamp/module identity but creates canonical Styx V1 on fresh installations.
  `20261021000000_migrate_oban_storage_to_styx.exs` adopts existing Oban jobs,
  preserving IDs, states, payloads, errors, attempts, timestamps and sequence high
  water. SQL NULL `meta`/`tags` become `{}`/`[]`; nullable `attempted_by` is retained.
  Old peer leases are discarded, and empty legacy tables remain for rollback.
- **API or background-job impact**: use `Styx.*`, `Styx.Migration` and Styx telemetry;
  application worker module names, seven queues, concurrency, cron schedules,
  transaction boundaries and provider-attempt behavior are unchanged.
- **Config / env impact**: config is under `Styx`; the existing `:oban_enabled`
  maintenance switch still disables consumers. No new environment variables.
- **Security / auth / trust-boundary impact**: no provider/auth changes. Runtime
  verification uses disposable databases and synthetic workers without mail I/O.

## Implementation notes

- **What changed**: seven direct dependencies exact-pin Hex `styx` `0.1.1`.
  Only the Oban/Styx entries change in `mix.lock`.
- **Why this approach**: Styx renames modules, SQL storage and notification
  channels, so dependency replacement alone cannot adopt persisted Oban jobs.
  Canonical Styx storage avoids maintaining a custom runtime engine.
- **Alternatives considered**: table renaming would retain incompatible enum,
  migration-history and array definitions; rewriting old queued payloads is
  unnecessary because application worker names remain stable.
- **Rollback notes**: stop every producer/consumer for either direction. The
  migration rejects executing jobs, independent histories and oversized legacy
  array elements rather than truncating data. Reverse migration copies current
  Styx state and new jobs into the retained old schema; it does not restore a
  stale snapshot. An unsupported old enum state rejects rollback atomically.
  Only the cutover migration is reversed with the new binary. Fresh Styx installs
  have no retained Oban schema and cannot use this rollback path.

See the [deployment runbook](../../../../docs/DEPLOYMENT.md#oban-切换到-styx) for
the non-rolling upgrade and exact reverse-migration command. Retained rollback
tables must not be written to or removed manually.

## Validation

- Old Oban baseline: `mix test --seed 20261021`, 1,598 tests, zero failures.
- New strict test compile: `mix compile --warnings-as-errors`, passed.
- Real-SQL migration suite: 14 tests, zero failures. Covers fresh install, safe
  states, nullable legacy fields, sequence high water, reverse migration of
  current/new jobs, and transactional rejection of unsafe inputs.
- Fresh dedicated database migration: passed.
- Independent namespace/storage compatibility review: no actionable findings.
- Application regression: all 1,612 tests passed across the umbrella apps,
  including the 14 new SQL migration tests. Initial Web run failed because the
  worktree lacked generated Duskmoon manifests; `mix assets.build` and the focused
  Web rerun (198 tests) passed. The initial failure log is retained.
- `mix format --check-formatted` and `git diff --check`: passed.
- Actual Oban 2.24.1 database upgrade: six synthetic jobs in six nonexecuting
  legacy states preserved all 19 durable fields and sequence high
  water (10,000). Canonical Styx V1 was created; retained old tables were empty.
- Actual `Manifold.Data.Supervisor` runtime: default PostgreSQL notifier and
  Database peer acquired leadership, with testing disabled and only a synthetic
  queue enabled. The adopted job completed at attempt 3; new ID 10,001 completed.
  After acknowledged consumer shutdown, pending ID 10,002 completed in a fresh
  VM. Styx/tzdata started, Oban/provider-facing apps did not; UTC and IANA timezone
  calculations succeeded.
- Reverse migration: all eight current rows, including new jobs and their latest
  terminal states, matched exactly and loaded through the original Oban schema.
  Sequence high water remained 10,002; canonical Styx storage was removed.
- Local temporary evidence: `/tmp/manifold-styx-full-tests.log` (initial Web
  asset failure), `/tmp/manifold-styx-web-tests.log` (successful rerun), and
  `/tmp/manifold-styx-runtime-verification/*-result.json`. Retained harness setup
  failures concern relocated build symlinks, fixture scheduling and telemetry
  initialization; no repository workaround was required.
- `mix duskmoon_bundler.js.check`: not required; no JavaScript changes.

## Post-task

- **Follow-ups**: production rollout requires the documented maintenance window;
  the running development database has not been migrated by this implementation.
- **Opened issues / TODOs**: none; no upstream blocker found.
- **Docs updated**: README, current architecture and deployment guide,
  module/deployment ownership, sync-button telemetry and account-action recovery
  examples.

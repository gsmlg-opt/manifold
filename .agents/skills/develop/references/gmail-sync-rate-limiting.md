# Gmail receive-sync rate limiting

## Feature

- **Name**: Gmail receive-sync pacing and shared cooldown
- **Date**: 2026-10-09
- **Owner/Requestor**: Manifold / user-approved Gmail sync repair
- **Status**: done

## Scope and module ownership

`manifold_connectors` owns `GmailSyncLimiter`, its application supervision,
`Provider.Gmail`, `Sync`, and corresponding tests. Root `config/config.exs`
contains pacing defaults. Other apps retain their existing boundaries.

The previous uncommitted OAuth issuer and completion-diagnostics fixes are
preserved separately. This feature does not change OAuth flow or sending.

## Design and data impact

- No migration or new persisted credential data.
- `gmail_sync: [interval_ms: 500, page_size: 50]` is application configuration;
  no new environment variables or OAuth settings.
- A supervised local GenServer keys admission by internal authorization UUID.
  It holds only internal deadlines, counters and monitored claims; it receives
  sanitized rate-limit errors, never raw provider bodies or credentials.
- `Sync` replaces caller provider context after authorization checkout, outside
  DB transactions. Successful checkpoint resets only its matching generation.
- One mailbox request may run per authorization; next admission occurs at least
  500 ms after completion. Callers wait briefly and recheck admission after waking.
- Initial list, incremental history, raw message and history-reset profile calls
  are paced. Token exchange, refresh, userinfo and sending are unpaced.
- Temporary limits install shared cooldown before claim release. Active cooldown
  avoids HTTP and returns the remaining delay for durable Oban snooze. Fallback
  30/60/120/240/300 seconds adds up to one second of jitter; valid longer server
  retry delays always win. Numeric/HTTP-date Retry-After and Google retry
  timestamps are parsed without retaining raw response text.
- Explicit `dailyLimitExceeded` yields permanent `daily_quota_exceeded`, cancels
  the attempt and points to Google Cloud quotas. Existing five-minute polling
  can revisit it. Unknown 403 reasons retain generic rejection classification.
- Accepted imports survive partial-page failure; cursor checkpoint remains
  page-atomic and retries skip accepted raw downloads. Monitors release claims
  if their caller exits. No distributed or cross-restart quota budget is promised;
  existing Oban retry scheduling survives restart.

## Implementation and rollback notes

Small pages and shared request admission fit existing synchronous adapters and
avoid a new database-backed partial-page queue. Lowering only page size leaves
requests unpaced. To roll back, revert feature-only provider/sync/config changes
and remove the limiter supervision/module; imports and existing cursors remain
compatible.

## Official sources

Retrieved 2026-10-09:

- [Usage limits](https://developers.google.com/workspace/gmail/api/reference/quota):
  1,200,000 project units/minute, 6,000 user/project units/minute;
  messages.get costs 20, list 5, history.list 2, getProfile 1. Two get requests
  per second use approximately 2,400 units/minute. These values supersede older
  15,000/user and 5/get guidance. 80M/day is a billing threshold, not a hard cap.
- [Error handling](https://developers.google.com/workspace/gmail/api/guides/handle-errors):
  temporary request limits differ from configured daily caps; 429 may reflect
  bandwidth/concurrency shared across clients, with long retry delays.
- [Sync](https://developers.google.com/workspace/gmail/api/guides/sync) and
  [batch](https://developers.google.com/workspace/gmail/api/guides/batch): retain
  raw cache/history recovery; batching still costs quota. Our 50-item page is a
  checkpoint policy, not Google's batch-size quota.

## Validation

- Limiter/provider RED observed before implementation; combined GREEN:
  34 tests, 0 failures.
- Sync RED reproduced missing trusted context and zero-spacing requests.
- Combined scoped limiter/provider/sync suite: 86 tests, 0 failures.
- Changed-file formatting and strict compile: PASS.
- Independent spec review: PASS. Quality review found a daily-quota telemetry
  allowlist omission; fixed with RED/GREEN diagnostic persistence coverage.
- Final independent quality recheck: PASS; no remaining actionable findings.
- Main workspace strict compile and changed-file format: PASS after integration;
  baseline hashes matched and earlier OAuth changes were untouched.
- Local `devenv processes restart manifold` completed; `/settings/oauth` HTTP 200.
- Restart left one old executing job orphaned (attempt timestamp before new
  server start). Only that exact Gmail sync job was requeued with a guarded
  update; existing messages/cursors were preserved.
- Real Gmail page completed at 2026-10-09T03:34:28Z: 50 messages, no new
  rate_limited records. Imported total grew from 9,356 to 9,406, page cursor
  advanced, and the next page started. Successful message completion gaps were
  minimum 780.3 ms / median 836.1 ms. These are import completion timings;
  deterministic tests separately prove actual request admission spacing.
- Whole-mailbox completion is not established; initial sync remains active.
  Real long-cooldown behavior was not triggered in this post-reload sample;
  mocked integration tests verify server deadlines, shared admission and resume.
- No frontend changes; JS/asset checks not required. No umbrella test suite run.

## Post-task

- No upstream dependency issues identified.
- Multi-runtime or cross-restart quota accounting requires separate design.
- Design: `docs/superpowers/specs/2026-10-09-gmail-sync-rate-limiting-design.md`.
- Plan: `docs/superpowers/plans/2026-10-09-gmail-sync-rate-limiting.md`.
- Initial implementation scope excluded publication. Follow-up user authorization
  on 2026-10-09 requested worktree merge, commit to main and push to origin/main.
  The verified worktree was fast-forwarded into main and its branch/worktree
  cleaned. Pre-push scoped Gmail/Sync/OAuth/Google-login checks passed:
  125 tests, 0 failures, changed-file formatting and strict compilation PASS.
- Releases and outbound messages remain outside scope.

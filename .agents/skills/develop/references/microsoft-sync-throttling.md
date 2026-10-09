# Microsoft Graph synchronization throttling

## Scope and ownership

Implemented 2026-10-09 in `manifold_connectors` and `manifold_outbound`.
`MicrosoftSyncLimiter` owns local admission and cooldowns; the connector Graph
adapter owns HTTP classification; `Sync` owns durable polling progress; OAuth
completion and outbound submission construct trusted mailbox contexts.
No migration, OAuth scope change, or new environment variable is required.

## Request admission and retry

- `config/config.exs` sets `microsoft_sync: [interval_ms: 500,
  max_concurrency: 2]`. Request starts are spaced and at most two admitted
  Graph requests for a mailbox overlap. Other mailboxes remain independent.
- Scope is `{:microsoft, local_mailbox_uuid}`, shared by identity/folder setup,
  delta, raw MIME downloads/membership probes, and outbound Graph submission.
  Callers construct this from trusted local account records, never access tokens.
- Claims monitor their caller, so exceptions or terminated workers release slots.
  Short admission waits occur outside database transactions. Cooldowns return
  immediately with remaining retry seconds rather than keeping workers asleep.
- Receive HTTP 429/500/502/503/504 and transport errors establish a shared
  cooldown. Numeric or HTTP-date `Retry-After` is honored; missing/invalid headers
  use exponential 30/60/120/240/480/900-second fallback plus up to one second of
  jitter. Existing longer deadlines cannot be shortened by concurrent errors.
- Req retries stay disabled. Receive jobs use existing durable Oban snooze;
  normal enqueue reuses incomplete jobs, preserving their scheduled delay.
- Outbound definite 429 rejection shares cooldown. Uncertain POST transport or
  server outcomes keep their existing uncertain classification and are never
  replayed by the limiter. A pre-dispatch cooldown is safe to retry and returns
  `provider_cooldown`; fenced persistence refunds that local attempt so waiting
  cannot exhaust the outbound provider-attempt budget. Actual 429 responses still
  count as provider attempts.
- Admission and backoff counters are local to one application VM. Oban retry
  deadlines are durable; in-memory state is not retained across restarts or
  coordinated across multiple VMs.

## Polling and diagnostics

- Each five-minute Microsoft poll checks every delta cursor, using the existing
  one-page jobs and one-second continuation snooze. Starting a fresh completed
  cycle clears only completion markers, retaining opaque next/delta positions.
- Pending pagination, initial sync, and failed/throttled cycles resume without
  invalidating folders already checked. `last_synced_at` advances only when the
  full cycle finishes; removal of the final pending folder also ends the cycle.
- Safe sync telemetry retains `http_429`, `http_503`, `http_504`, and
  `transport_error` rather than reporting generic `sync_failed`. It contains no
  raw provider bodies or credentials.
- Keep `$select`, `odata.maxpagesize=100`, immutable IDs, accepted raw cache,
  mailbox existence checks for membership removals, and checkpoint fences.

## Validation

Scoped tests cover actual dispatch spacing and concurrency with controlled
clocks/barriers, independent mailboxes, killed callers, late wakeups, cooldown
propagation, Retry-After and fallback, stale success, and absence of HTTP replay.
Graph adapter, OAuth setup, sync, and outbound tests cover the integrated paths,
multi-folder cycles, pagination, interrupted retry, and folder removal.
Run the corresponding test files in `devenv shell`, plus scoped formatting and
strict compile. Live quota-exhaustion tests are intentionally not performed.

2026-10-09 verification: 156 connector tests and 95 outbound tests passed across
the scoped files (the worker fixture was updated to advance the admission clock
as well as its Oban schedule, then all 18 worker tests passed). Changed-file
formatting, `git diff --check`, and `mix compile --warnings-as-errors` passed.
Local Manifold was restarted, HTTP readiness returned 200, and two snapshotted
in-flight SyncAccount jobs were recovered with ID/attempt-time guards. Existing
258 imported Outlook messages remained intact. All nine live cursors completed
the poll cycle, the account returned to `connected` without an error, and the
completion span was approximately 361 seconds while slow IMAP jobs shared the
queue. Version bumps and publication use the repository Release workflow.

## Follow-up

Historical `repair_received_at` scans/writes on each sync page remain a separate
database performance task. The connectors queue still has two slots shared with
IMAP/Gmail; five minutes is the polling schedule, not a guaranteed full-cycle
latency under queue pressure. Slow IMAP pages can delay Microsoft continuations
without resetting completed folders. Queue isolation is a separate follow-up.
For deployments with several Graph-calling VMs,
replace local admission with shared enforcement before claiming a deployment-wide
mailbox concurrency limit.

## Official references

- https://learn.microsoft.com/en-us/graph/throttling-limits#outlook-service-limits
  documents 10,000 requests/10 minutes and four concurrent requests per app ID
  and mailbox. These are service ceilings, not this application's defaults.
- https://learn.microsoft.com/en-us/graph/throttling describes honoring
  Retry-After and exponential fallback.
- https://learn.microsoft.com/en-us/graph/delta-query-messages describes per-folder
  delta cursors and opaque pagination links.

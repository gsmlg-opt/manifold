# Gmail sync rate limiting implementation plan

> **For agentic workers:** Use subagent-driven-development to execute the owned tasks with scoped checks and independent review.

**Goal:** Apply the approved two-request-per-second Gmail receive-sync pace, 50-message pages, shared cooldown and server-aware backoff without losing imports or lifecycle fences.

**Architecture:** A supervised local limiter serializes admission per internal authorization UUID and monitors the caller that owns each request claim. The real Gmail adapter uses this limiter only when Sync supplies a pacing context; Sync creates a generation snapshot before a page and resets the backoff only after a current successful checkpoint. Long cooldowns return a Provider.Error for the existing durable Oban snooze path.

**Tech Stack:** Elixir/OTP GenServer, existing Req transport and Req.Test, Ecto/Oban, ExUnit with a controllable monotonic clock.

## Shared contract

Module `Manifold.Connectors.GmailSyncLimiter`:

```elixir
{:ok, server} = GmailSyncLimiter.start_link(name: nil, interval_ms: 500, clock: clock, jitter: jitter)
context = GmailSyncLimiter.context(authorization_id, server: server, wait: wait)
GmailSyncLimiter.run(context, fn -> {:ok, response} end)
GmailSyncLimiter.success(context)
```

`context/2` returns a map with `key`, `server`, `wait`, and current `generation`.
Default server is the supervised module name; default wait is Process.sleep/1.
`run/2` atomically acquires a monitored request claim, waits/rechecks only short
pacing delays, and releases on success, failure or caller exit. At most one
request per key is in flight. The next request waits at least the configured
interval after the previous request finishes, making actual dispatch spacing safe
even when a previously admitted process wakes late.

When the callback returns a rate_limited Provider.Error, record a newer generation
and shared deadline before releasing the claim, apply max(valid server delay,
fallback backoff+jitter), and return the normalized error with that retry delay.
An already active cooldown returns the remaining delay without incrementing the
counter or calling the callback. Fallback delays are 30/60/120/240/300 seconds;
jitter is 0..1000 milliseconds, rounded up for Oban. `success/1` clears only its
matching generation's consecutive-error counter, never a newer cooldown.

Gmail receive adapter methods use `opts[:gmail_sync]` as this context. Calls
without the context retain their existing unpaced behavior. `Sync` creates the
context using the receive snapshot's authorization UUID, with isolated test
overrides from the internal `opts[:gmail_sync_limiter]` keyword list. Ignore any
caller-supplied provider context by replacing it with this trusted context.

## Task 1: Shared limiter and supervision

Ownership: new `lib/manifold/connectors/gmail_sync_limiter.ex`, new corresponding
test, `lib/manifold/connectors/application.ex`, `config/config.exs`.

- [x] Write deterministic failing tests using Agent-backed clock and caller wait
      hooks: same-key spacing, different keys, late wakeups, one in-flight claim,
      caller exit, active/new cooldown without HTTP callback, backoff cap, long
      server delay lower bound, current success reset and stale success fence.
- [x] Run only the limiter test and record its expected RED output before implementation.
- [x] Implement the shared contract with monitored owners and no sleeping inside
      the GenServer. Store only UUID keys, internal times/counters and monitors.
- [x] Add the limiter to the existing one_for_one connectors supervisor.
- [x] Add narrow `gmail_sync` configuration defaults interval_ms: 500 and page_size: 50.
- [x] Run the limiter test and changed-file formatting.

## Task 2: Real Gmail adapter and error handling

Ownership: `lib/manifold/connectors/provider/gmail.ex` and its provider test.

- [x] Change list/history expectations to 50 and add failing tests proving sync
      context covers list/history/raw-get/history-reset profile, while OAuth
      exchange/refresh/userinfo do not use it.
- [x] Add RED tests for 403 temporary user/project reasons versus explicit daily
      cap; numeric/date Retry-After and safe Google retry timestamps; largest
      valid retry lower bound, invalid/past values, and response-body redaction.
- [x] Use `GmailSyncLimiter.run/2` around the normalized mailbox request callback;
      thread the existing provider opts through API helper/history fallback.
- [x] Separate dailyLimitExceeded as permanent :daily_quota_exceeded with an
      operator-facing Google Cloud quota message. Do not invent a quota category
      for an unknown reason. Preserve existing reconnect/policy/server failures.
- [x] Run only the provider test and changed-file formatting.

## Task 3: Sync integration and checkpoint preservation

Ownership: `lib/manifold/connectors/sync.ex`, its test, feature reference and
approval/verification updates to the design and this plan.

- [x] Write RED integration coverage for the trusted authorization-key context,
      same page's success reset and stale-generation guard, unchanged cursor and
      persisted accepted message after midpage cooldown, and resume that skips
      previously imported raw content.
- [x] Create the limiter context after auth checkout and outside DB transactions;
      pass it through existing provider opts to Gmail sync only.
- [x] Call success(context) after a successful current checkpoint; leave the
      existing Provider.Error -> Oban snooze/cancel and lifecycle fences intact.
- [x] Update the feature reference with official sources, behavior, ownership,
      runtime limits and actual verification evidence.

## Verification and local runtime

- [x] Run the limiter, Gmail provider and sync test files together:

```sh
mix test apps/manifold_connectors/test/manifold/connectors/gmail_sync_limiter_test.exs apps/manifold_connectors/test/manifold/connectors/provider/gmail_test.exs apps/manifold_connectors/test/manifold/connectors/sync_test.exs
```

- [x] Check formatting of changed Elixir/config files and compile with warnings
      as errors. No full umbrella tests or unrelated repairs.
- [x] Complete independent spec-compliance review, then code-quality review.
- [x] Copy only this feature's verified files to the active workspace after
      checking baseline hashes; preserve all earlier OAuth edits and unrelated work.
- [x] Restart only the local manifold process, verify HTTP readiness, inspect
      safe activity/job/cursor counts to establish actual pacing/cooldown/progress.
- [x] Report unit/mock checks separately from real Gmail observations. Do not
      claim an entire mailbox completed from one resumed job or one sample.

No commits, pushes, releases, migrations or outbound messages are part of this task.

## Recorded verification

Expected RED was observed for the absent limiter, provider behavior, Sync context/spacing,
and daily-quota telemetry allowlist. Final combined GREEN: 86 tests, 0 failures.
Changed-file format and strict compile passed. Independent spec review passed.
Quality review diagnostic finding was fixed; final quality recheck passed.
Main hashes matched, feature-only integration completed, strict compile/format passed.
Service reloaded and HTTP readiness returned 200. One exact pre-restart orphaned
executing job was recovered. Real Gmail then checkpointed 50 messages without a
new rate-limit error; total accepted imports grew 9,356 -> 9,406 and next page started.
Completion gaps min780.3ms / median836.1ms are observational evidence, not an HTTP
request trace. Full mailbox completion and a real new long-cooldown cycle remain
unproven; deterministic/Req.Test coverage establishes those implementation paths.

Environment note: one accidental devenv invocation from the worktree failed before
tests because it selected an absent worktree Postgres socket. All reported scoped
GREEN checks used the main devenv shell followed by cd into the worktree.

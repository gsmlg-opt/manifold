# Gmail sync rate limiting

Date: 2026-10-09. Status: approved by the user; implemented and verified locally.

## Problem and current behavior

Gmail authorization now succeeds. Initial receive synchronization has recorded
repeated `rate_limited` failures while successfully importing messages between
failures. The adapter lists up to 500 messages and downloads new raw messages
serially without pacing. A temporary provider failure snoozes the existing Oban
job for a numeric Retry-After value or 30 seconds. Successfully imported messages
remain stored; retries skip their raw downloads, and the page cursor advances
only after the whole page succeeds.

The current deployment has one connectors application and two connectors queue
workers. Rate limiting must be shared by overlapping sync attempts for the same
Gmail authorization, rather than reset for every job or page.

## Official research

Sources retrieved live on 2026-10-09:

- [Gmail usage limits](https://developers.google.com/workspace/gmail/api/reference/quota),
  updated 2026-09-10: 1,200,000 quota units per minute per project; 6,000 per
  minute per user within a project. `messages.get` costs 20 units,
  `messages.list` 5, `history.list` 2, `getProfile` 1, and `messages.send` 100.
  The 80,000,000 daily project figure is a billing threshold, not a universal
  hard daily cap. Older 15,000-user/5-unit-get figures must not guide this fix.
- [Handle Gmail errors](https://developers.google.com/workspace/gmail/api/guides/handle-errors),
  updated 2026-09-15: 403 `rateLimitExceeded` and `userRateLimitExceeded` require
  traffic reduction and exponential backoff. `dailyLimitExceeded` identifies a
  configured daily project cap. A 429 may instead indicate bandwidth, sending,
  or concurrent request limits shared across clients of the same Google user.
  Long limits can persist for hours; responses may contain a retry time.
  Retry guidance starts after at least one second, doubles the interval, adds
  random jitter up to one second, and caps the backoff. No numeric concurrent
  request limit is published. These pages do not promise a Retry-After header.
- [Synchronize Gmail clients](https://developers.google.com/workspace/gmail/api/guides/sync):
  cache downloaded raw/full messages and use history-based incremental sync.
  An expired history cursor returns 404 and requires full synchronization.
- [Batch requests](https://developers.google.com/workspace/gmail/api/guides/batch):
  every inner call still consumes quota; batching is not a rate-limit bypass.
  The recommendation of at most 50 calls concerns HTTP batches, not list page
  size. The 50-message list page below is our checkpoint/fairness policy.
- [Workspace bandwidth limits](https://knowledge.workspace.google.com/admin/gmail/gmail-bandwidth-limits):
  Workspace IMAP download/upload limits are 2,500/500 MB per day. Gmail's error
  guide links the API allowance to those sizes but counts API traffic separately.
  This numeric Workspace allowance is not confirmed for the current consumer
  gmail.com account and will not be treated as its guaranteed API allowance.

## Options and recommendation

1. **Shared request pacing plus small pages (recommended).** Pace actual Gmail
   mailbox API requests, share the schedule across same-authorization jobs, and
   checkpoint after smaller pages. This fits the existing synchronous adapter
   and preserves page-atomic cursor handling. Waiting happens outside database
   transactions. A page of 50 new messages takes roughly 25 seconds plus network
   and import time at the proposed rate.
2. **Only reduce page size or increase the gap between jobs.** Less code, but
   leaves requests inside a page unpaced and can still burst into Gmail limits.
3. **Persist a new request budget and partially processed page queue.** Can yield
   workers between individual requests and coordinate replicas, but adds schema
   and cursor state changes beyond the current single-runtime fix.

## Proposed behavior

- Add a supervised Gmail sync pacer in `manifold_connectors`. All mailbox API
  requests from receive sync reserve a shared slot keyed by the stable internal
  OAuth authorization UUID. Do not key on access tokens, email addresses, or
  pasted authorization data.
- Default to at most two mailbox API requests per second per authorization,
  with no initial burst. The most expensive sync call is `messages.get` at 20
  units, so even an all-get stream uses about 2,400 units/minute, leaving room
  beneath 6,000 for other clients and sending. With two queue workers, this
  runtime's worst-case sync traffic is about 4,800 units/minute, far below the
  project quota. This is a single-runtime guarantee, not a distributed quota
  reservation across multiple application replicas or external API clients.
- The pacer schedules short waits in the caller, outside database transactions;
  its supervised server never sleeps and different authorizations remain
  independent. Maintain spacing across page boundaries and concurrent callers.
  Recheck atomic admission after every wake, rather than treating a past slot
  reservation as permission to dispatch. Keep at most one sync API request in
  flight per authorization and release its claim on completion or caller exit.
  A newer long cooldown returns a durable snooze instead of making an already
  waiting worker sleep for minutes. Late wakeups must not cause dispatch bursts.
- Set Gmail sync list/history page size to 50. Preserve the frozen bootstrap
  history anchor, history-404 recovery, deduplication, accepted message cache,
  lifecycle fences, and page-atomic cursor checkpoint.
- Carry the pacing context through existing `provider_opts` into list, history,
  raw-get, and history-reset profile requests. OAuth token exchange, refresh,
  userinfo, and outbound sending are outside this receive-sync pacing scope.
- On a Google rate-limit response, retain a safe reason code and parse numeric
  or HTTP-date Retry-After if present, and a documented-style retry timestamp in
  the Google error message. Never log or store the raw response message/body.
  Use the largest valid server delay as a lower bound.
- Use a local fallback of 30 seconds, exponential increases to 60/120/240/300
  seconds, and fresh jitter up to one second when repeated limits lack a server
  delay. The five-minute cap is our conservative operational policy, not a
  Google-mandated value; a larger server retry time always wins. Clear the
  consecutive-limit state after a successful page only if that page's limiter
  generation still matches; never clear a newer concurrent cooldown. Place long waits into Oban's
  durable scheduled retry, not a worker sleep. Retain the same-authorization
  cooldown in the shared pacer so another local caller cannot bypass it.
- Classify an explicit daily project cap separately from temporary request
  throttling, with a message directing the operator to Google Cloud quotas.
  Cancel that attempt rather than enter the short rate-limit retry loop. The
  existing five-minute poll may recheck it after a quota adjustment; this proposal
  does not add a new operator-blocked connector lifecycle state.
  Keep unknown provider reasons generic rather than asserting they are minute
  quota limits. Configuration, policy, and expired credentials remain distinct.

The new pacing settings belong to a narrowly scoped application configuration
entry, not encrypted OAuth credential settings or environment secrets. No database
migration is proposed. Existing Oban scheduling preserves queued retry times
through restarts; short pacer reservations reset on runtime restart. Strict
cross-replica or cross-restart shared quota accounting is outside this change.

## Acceptance checks

- A deterministic fake-clock test proves same-authorization requests cannot
  exceed two per second, including overlapping callers and page boundaries.
  Different authorizations are paced independently. The limiter records no
  token/code/state/email material.
- Tests cover delayed simultaneous wakeups, a new cooldown installed while
  another caller waits, caller exit releasing an in-flight claim, and a stale
  successful page not clearing a newer cooldown.
- Real Gmail adapter tests through Req.Test prove list, history, raw-get and
  history-reset profile requests invoke pacing; exchange/refresh/userinfo do not.
- Adapter tests cover numeric/date Retry-After, Google retry timestamps, invalid
  values, long cooldown lower bounds, rate-limit reason classification, daily
  quota errors, and response-body redaction.
- Sync tests prove increasing backoff, success reset, page-size/continuation,
  unchanged cursor after midpage failure, retained first-message import, and
  resume without re-downloading accepted raw content. Lifecycle/configuration
  races retain their existing fences.
- Run only limiter, Gmail adapter, and sync test files, plus changed-file
  formatting and strict compile checks. Preserve the existing OAuth fixes in the
  working tree. Update the repository feature reference with implementation and
  validation results.
- Reload the local runtime after checks and observe real synchronization through
  activity records and cursor/message counts without logging credentials or
  mail content. A resumed job is not proof that a complete mailbox sync passed;
  report the actual observed progress and remaining Google cooldown separately.

## Expected file scope

- New `apps/manifold_connectors/lib/manifold/connectors/gmail_sync_limiter.ex`
  and its test.
- `apps/manifold_connectors/lib/manifold/connectors/application.ex`.
- `apps/manifold_connectors/lib/manifold/connectors/provider/gmail.ex` and
  `apps/manifold_connectors/test/manifold/connectors/provider/gmail_test.exs`.
- `apps/manifold_connectors/lib/manifold/connectors/sync.ex` and
  `apps/manifold_connectors/test/manifold/connectors/sync_test.exs`.
- A narrow `gmail_sync` configuration entry in `config/config.exs`.
- `.agents/skills/develop/references/gmail-sync-rate-limiting.md`.

This proposal does not grant commit, push, release, or send-test authorization.

## Implementation verification

Completed with 86 scoped tests, changed-file formatting, strict compilation and
independent spec/quality review. No migration. Service was reloaded and a real
50-message page checkpointed without a new rate-limit error; initial mailbox sync
continues. See the feature reference and plan for evidence and runtime limits.

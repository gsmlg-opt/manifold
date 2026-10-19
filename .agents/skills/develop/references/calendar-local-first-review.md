# Calendar local-first implementation

- Updated: 2026-10-19.
- Status: implemented and verified in `codex/calendar-local-first`, based on
  `5a6825fa1edcc8cfdbf79b8e10ff882b0f935ff8`; no deployment or release claim.
- Operator guide: [Calendars](../../../../docs/CALENDARS.md).
- Shared interfaces: [implementation contract](../../../../docs/superpowers/implementation/calendar-contract.md).
- Verification: [implementation evidence](../../../../docs/superpowers/implementation/calendar-validation.md).
- Approved scope and original findings:
  [correction plan](../../../../docs/superpowers/plans/2026-10-19-calendar-local-first-correction.md).

## Ownership and entry points

| Module/application | Responsibility |
| --- | --- |
| `manifold_data` | Stable `Calendar`/`CalendarEvent`, `CalendarConnection`, `CalendarBinding`, `CalendarSyncResource`, `CalendarEventBinding` and immutable `CalendarSyncAttempt` records; additive migrations; `CalendarSyncState` stages durable per-target intents inside canonical mutation transactions |
| `Manifold.Calendars` | Provider-independent calendar/event CRUD, local revisions and tombstones, occurrence/series commands, explicit copies and sync summaries |
| `Manifold.Calendars.Time` / `Recurrence` | DATE/UTC/floating/TZID semantics, viewing timezone conversion and bounded RRULE/RDATE/EXDATE expansion with original-slot exceptions and explicit failures |
| `Connectors.CalendarConnections` | Independent encrypted Calendar credentials, verified Google subject/Apple principal, Calendar-only OAuth authorization, refresh and disconnect impact fencing |
| `Connectors.CalendarSync` | Persisted enrollment and re-enrollment previews, target lifecycle, complete-batch reconciliation, conflict resolution, leased dispatch and unknown-outcome recovery |
| `Connectors.CalendarSync.Google` / `ICloud` | Provider codecs, bounded snapshots, conditional writes and exact resource/instance identity; retain raw JSON/ICS and report unsupported field coverage |
| `Connectors.CalendarMigration` | Read-only identity/baseline review and explicit activation of retained legacy mappings |
| `Connectors.Jobs.SyncCalendar` / `PollCalendars` | Wake and recover durable work; jobs are not the authoritative pending state |
| `manifold_account_lifecycle` / legacy `Connectors.ICloud` | Preserve calendars and Calendar connections through mailbox lifecycle; legacy `SyncICloud` admits Contacts only |
| `manifold_web` | Calendar month/agenda views, visibility separate from write destination, Calendar connection controls, persisted enrollment/claims, target status, conflict impact and change notifications |

Contacts retains its Account-owned connection and synchronization path. Calendar
credentials remain separate even for the same Apple login. Keep application
boundaries: schemas/transactional staging in Data, local commands in Calendars,
provider/network operations in Connectors, presentation in Web.

## Identity, transactions and synchronization invariants

Local calendars/events work without a mailbox, cloud credential or network.
Their IDs survive target addition, pause, detach, reauthorization and Account
purge. One local calendar can synchronize with Google and iCloud simultaneously.
`series_id` groups canonical components; UID/title/time similarity never proves
identity across independent sources.

Canonical changes and durable intents commit together. Each enrolled target owns
its desired/acknowledged revisions, covered semantic baseline, checkpoint, raw
resources, conflicts and immutable sent vectors. Accepted inbound changes create
canonical revisions and stage other enrolled targets atomically. Source echoes
do not increment revisions. A target's success cannot acknowledge another target;
a late old response cannot clear newer work or resurrect a tombstone.

Use the contract lock order: Calendar, bindings by ID, resources by ID, events by
ID. Connection lifecycle does not acquire Calendar locks while holding connection
locks. Perform no network I/O inside database transactions. Notify
`calendar:changes` after committed commands/sync; Oban remains a wakeup mechanism.

Only complete, validated snapshots advance checkpoints or establish remote event
deletions. Container loss, revoked access, authentication errors and incomplete
pagination retain local data and the other target's work. Three-way comparison
uses canonical local state, the target baseline and covered remote projection;
ambiguous concurrent versions remain explicit conflicts with both candidates.
Absent unsupported fields do not mean deletion or complete synchronization.

## Enrollment, lifecycle and uncertain requests

`CalendarSync.preview/4` records the exact local revisions and remote resource
versions plus the impact of imports on other targets. `confirm/4` revalidates the
preview before enrolling selected historical uploads/imports. Explicit identity
claims reuse proven mappings; differing versions remain conflicted. Confirmed
active/paused targets enroll newly created local events. Historical local events
never upload merely because a target was discovered or added.

Pause retains mappings, pending revisions and unresolved attempts while stopping
new requests; another target can continue. Resume reconciles before dispatch.
Detach archives the target and suppression state without deleting local or remote
data. `reenroll_preview/2` reuses that target identity and unresolved evidence,
archives the prior manifest and requires a fresh selection/confirmation. Unselected
history stays suppressed. Same-identity reauthorization preserves mappings but
does not silently reactivate detached targets. Deleting a local calendar archives
it and detaches its targets; it does not delete the remote container/events.

Reserve resource identities before create dispatch. Google maps individual master
and detached-instance resources; iCloud maps complete series resources containing
multiple components. Store the exact destination, payload, precondition and sent
component revisions in an immutable attempt. Creates use `If-None-Match: *`;
updates/deletes require strong `If-Match` ETags. Detached Google edits resolve the
exact original instance slot and compare its proven baseline before adopting its
ETag. Unknown provider properties and unrelated ICS components remain preserved;
unsupported scheduling or destructive whole-resource operations fail explicitly.

Before any replay, read the same resource for unresolved prepared/dispatched/
uncertain attempts. A result matching the sent projection settles only those sent
revisions; an unchanged baseline/proven absence permits a new conditional attempt.
A different result becomes a conflict. Worker death after remote acceptance leaves
durable dispatched evidence; lease recovery performs this same read/reconcile
path. Full VM restart verification remains a separate, unrun gate.

## Migration and authorization fences

Migrations `20261019000100`, `20261019000200` and `20261019000300` retain local IDs,
raw resources/ETags, original encryption context, dirty revisions, tombstones,
conflicts and unresolved attempts. Migration performs no HTTP requests or provider
writes. Legacy resource counters remain evidence, not invented per-component
acknowledgments; legacy attempts keep empty component vectors.

Migrated connections/targets start paused with identity/baseline review required.
`CalendarMigration.review/2` verifies the original credential identity, hydrates
semantic baselines and persists a read-only comparison. Activation re-fetches the
report and checks identity generation, target state/token and local revisions.
Changed review data requires another preview; unresolved attempts remain durable
for recovery, and old unbound drafts do not enroll automatically. Use `scripts/calendar_migration_probe.exs` only with an
empty disposable database containing `calendar_migration_` in its URL.

Quiesce the old Calendar writer before activating the new path; Contacts continues
through its existing worker. Retain additive schema and all attempt evidence for
rollback. After a write dispatch, restoring an older backup cannot undo remote
side effects: stop dispatch, preserve evidence and reconcile before choosing a
forward repair. Never run old and new Calendar writers on the same resources.

Google authorization uses PKCE, expiring single-use state and a session match,
Calendar scopes separate from Gmail, verified subject identity and encrypted
refresh credentials. Shared Gmail callback dispatch selects the Calendar handler
only for its matching Calendar session state. Provider-setting UUID/version is
checked before exchange and before saving authorization. Refresh admission and
final commit validate the provider generation; owner/generation/active status and
lease expiry fence late refresh responses. Failure releases its own lease without
changing a disconnected connection. Malformed token/scope/lifetime responses fail
closed; omitted refresh scope preserves the previously verified grant. Same-Apple
identity is proven by CalDAV principal discovery, not the supplied login string.

## Time, recurrence and provider limits

Occurrence queries use an exclusive upper date bound. DATE values keep their
calendar day; floating values follow the viewing zone; TZID recurrence keeps its
wall clock across DST. Generated gaps are skipped without consuming COUNT and
folds use the first occurrence. Moved/deleted exceptions retain the original slot;
removing an occurrence adds the proper exclusion rather than restoring the master
slot. Expansion limits/errors are explicit instead of silently omitting events.

Canonical reminders are sorted/unique popup/email minute offsets. Relative DISPLAY
alarms map to popup reminders; unsupported iCloud alarms retain raw content and
capability limits. Google inherited defaults are not treated as explicit empty
reminders. Preserve unknown ICS/JSON instead of reconstructing imported resources
from a simple projection. Invitation/RSVP scheduling, future-series splits and
remote container management remain outside the supported editing scope.

## Verification and remaining gates

The final scoped gate passed **280 tests**, covering Calendar, directly related
Data/Connectors/Lifecycle and Calendar/OAuth Web behavior, plus affected shared DAV
and Contacts regressions. Strict compilation, formatting and asset build passed.
The JS check reported **0 errors and 2 pre-existing warnings**. The disposable
migration probe passed with retained legacy state and zero provider HTTP calls.

Controlled actual localhost HTTP tests passed local CRUD to both targets, both
provider directions through the canonical local model, reminder propagation,
independent acknowledgment, pause/resume, unknown create response without duplicate
POST, recurring moved/deleted slots, and a worker killed after remote acceptance
recovering its durable attempt without another create. Adapter tests cover bounded
pagination, token expiration, conditional conflicts, raw content preservation and
capability limits. OAuth regressions cover generation changes during HTTP, lease
expiry/cleanup, malformed responses, single-use state and session dispatch.

**Full VM restart: NOT RUN. Real Google/iCloud authorization and joint
disposable-data read/write/reconnect acceptance: NOT RUN.** Controlled peers do not establish
real provider compatibility. See the linked validation record for exact commands,
logs, browser evidence and scope. Historical iCloud-only/stored-component plans and
acceptance remain dated evidence; this entry and the Calendar guide describe the
current implementation. There is no commit/push/release or production migration
claim in this record.

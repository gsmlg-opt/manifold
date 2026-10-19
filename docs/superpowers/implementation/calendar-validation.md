# Calendar correction validation

Date: 2026-10-19. Branch: `codex/calendar-local-first`. Source baseline:
`5a6825fa1edcc8cfdbf79b8e10ff882b0f935ff8` plus the implementation in this worktree.
Scope and authorization: [approved correction plan](../plans/2026-10-19-calendar-local-first-correction.md).
Interfaces: [implementation contract](calendar-contract.md).
Operations and cutover: [Calendars](../../CALENDARS.md).

## Results and boundaries

| Gate | Result | Evidence |
| --- | --- | --- |
| Scoped ExUnit regression | **PASS: 280 tests, 0 failures** | Final seed `541625`: Calendars 48, Connectors 164, AccountLifecycle 3, Web 65 |
| Changed Elixir formatting | **PASS** | `mix format --check-formatted` over changed/new `.ex` and `.exs` files |
| Strict compilation | **PASS** | `MIX_ENV=test mix compile --warnings-as-errors` |
| Frontend assets | **PASS** | `MIX_ENV=test mix assets.build` built CSS and JS; CSS `app-c9abdaaf.css`, JS `app-2cf0cf65.js` |
| JS sanity check | **PASS with existing warnings** | `mix duskmoon_bundler.js.check`: 0 errors, 2 unused `_error` catch-parameter warnings in unchanged `assets/js/app.js` |
| Documentation and whitespace | **PASS** | 11 changed/new Markdown files, 194 local targets/anchors; `git diff --check` |
| Legacy-schema migration rehearsal | **PASS** | Disposable database, preserved IDs/state/context, no invented component acknowledgments, no provider requests |
| Cross-provider requests and convergence | **PASS with controlled peers** | Actual localhost HTTP through both adapters, including all CRUD directions, recurrence, partial completion and unknown submission recovery |
| Killed-worker recovery | **PASS with controlled peers** | Kill the worker after accepted PUT; fresh worker reads durable attempt and recovers without another create |
| Browser local workflows and themes | **PASS in stated viewports** | Local CRUD, overlay/write separation, UTC recurrence, independent target status, month/agenda and date-input mode checks; final 390px/1440px layouts in sunshine/moonlight |
| Full application/VM restart against retained state | **NOT RUN** | Worker replacement and fresh DB reads do not establish a full VM restart gate |
| Real Google authorization/read/write/reconnect | **NOT RUN** | No real Google credentials or disposable provider calendar used |
| Real iCloud authorization/read/write/reconnect | **NOT RUN** | No real Apple credentials or disposable provider calendar used |
| Joint real Google/iCloud acceptance | **NOT RUN** | Controlled HTTP results do not establish deployed provider compatibility |
| Deployment, release and development DB migration | **NOT RUN** | Changes remain in the implementation worktree |

Final command output: `/tmp/manifold-calendar-final-complete-v2.log` (exit 0).
The earlier gate passed 279 tests with seed `152964`; the final 280 includes the
additional reminder-input regression and the final mobile rendering changes.
No full umbrella test run is claimed.

## What the automated tests establish

- Local calendar/event CRUD needs no mailbox or provider connection. Stable IDs,
  revisions, tombstones and atomic synchronization intents survive Account purge,
  target pause/detach, same-identity authorization and explicit re-enrollment.
- DATE, UTC, floating and TZID semantics are preserved. Bounded recurrence includes
  old masters, DST, RDATE/EXDATE, moved and cancelled exceptions. Occurrence/series
  copy and deletion preserve the selected business scope.
- Each target owns its desired/acknowledged revisions and baseline. A successful
  Google request does not acknowledge iCloud work. Late replies do not clear newer
  edits or revive local tombstones. Accepted inbound changes stage other targets
  atomically; echoes do not create new canonical revisions.
- Enrollment previews persist selections and revisions. Stale local or remote
  previews cannot activate uploads. Explicit re-enrollment retains the resource
  identity and unresolved attempts while suppressing unselected history.
- Complete snapshots/pagination and valid checkpoints establish remote deletions.
  Container loss, permission/authentication failure and partial batches retain local
  data. Concurrent edits and sparse cancellation against pending edits remain
  conflicts and do not propagate before acceptance.
- Durable attempts retain the exact payload, destination, precondition and sent
  vector. An unknown create is read back before any replay. A worker killed after
  remote acceptance leaves dispatched evidence that its replacement reconciles.
- Google instances resolve by proven parent/original slot. iCloud updates retain
  whole-resource data, including unknown fields and unsupported components.
  Unsupported scheduling/reminder coverage is explicit; inherited defaults are
  not silently erased.
- Calendar OAuth uses independent scopes, PKCE, single-use state, session matching
  and verified provider identity. Authorization and refresh responses are fenced
  by provider/connection generation and lease state, including changes during HTTP.
  Malformed replies fail without exposing credential material.
- The legacy iCloud writer admits Contacts only. Shared DAV and directly affected
  Contacts/Account/Web paths pass their scoped regressions.

The actual-HTTP scenarios are in
[`cross_provider_test.exs`](../../../apps/manifold_connectors/test/manifold/connectors/calendar_sync/cross_provider_test.exs).
Coordinator, adapter and OAuth tests remain separate so a codec-only pass is not
mistaken for cross-provider convergence or authorization evidence.

## Migration rehearsal

[`scripts/calendar_migration_probe.exs`](../../../scripts/calendar_migration_probe.exs)
creates legacy fixtures, then applies all new migrations in an empty disposable
database. The successful database was
`manifold_calendar_migration_audit_20261019_02`; output is in
`/tmp/manifold-calendar-migration-probe.log`:

```json
{"result":"PASS","canonical_events_preserved":5,"resources_preserved":4,"bindings_paused":1,"unknown_attempts_preserved":1,"invented_component_vectors":0,"auto_enrolled_drafts":0,"http_requests":0,"original_credential_context_preserved":true}
```

The fixture includes pending, conflicted and unknown legacy work, a tombstone and
an unbound local draft. The probe checks that legacy counters stay in retained
evidence rather than becoming fabricated event acknowledgments. Legacy unknown
attempts have empty component vectors. Connections retain their original
credential encryption context, and migrated targets require paused identity and
read-only baseline review before activation.

The first disposable probe (`_01`) stopped because the Ecto migrator call lacked
an explicit `all: true` strategy. The script was corrected and the fresh `_02`
database passed. That setup failure is not a successful migration result.

No development or production database was migrated. The probe performs no HTTP
request; real-provider read/write continuity after an upgrade remains unverified.

## Browser smoke

Browser checks use a dedicated test server on `localhost:4398`, a separate
`manifold_calendar_browser_20261019_01` database, disabled Oban dispatch and an
isolated Chrome context. Google/iCloud status fixtures have no real credentials
and remain paused. They test presentation, not a provider connection.

Observed before final layout review:

- Created a local calendar without Account/provider configuration; created,
  edited and deleted an all-day event while retaining its local ID through edit.
- Changed the default write calendar independently from visible calendars;
  hiding/showing a calendar removed/restored its events.
- UTC `20261019T233000Z` displayed as October 20 at 07:30 in `Asia/Shanghai`, with
  three daily occurrences on October 20–22 in both month and agenda views.
- Event details showed Google ACK 1 / desired 1 as synchronized independently
  from iCloud ACK 0 / desired 1 as uncertain, with readback recovery explained.

Final screenshot review exposed a mobile toolbar overlap and a hidden month-grid
without a mobile agenda fallback. The toolbar now wraps controls, has separated
Month/Agenda links and a full-width time-zone row on narrow screens. Month view
renders the mobile agenda; the LiveView regression asserts this fallback and the
explicit Agenda route. Native date/datetime inputs have mode-specific identities
to avoid patching an incompatible value into the previous input type.

Initial browser automation also outlived the test Sandbox's 120-second ownership
timeout, producing a failed-push console error. The disposable browser server was
restarted with unlimited Sandbox ownership for the final pass. That fixture
setting is not an application configuration change. Native confirmation handling
was retried using the page's button and accepted dialog; the event disappeared
and the details panel closed.

Final rebuilt-asset checks passed at 390×844 and 1440×1000 in sunshine and
moonlight. The connected LiveView showed all three 07:30 occurrences. The mobile
month route displayed the agenda fallback; the desktop route displayed the month
grid and hid that fallback. Switching to Agenda and opening mobile navigation
worked. Document `scrollWidth` equalled its `clientWidth` (375px mobile, 1425px
desktop), with no page-wide horizontal overflow. The all-day toggle changed native
datetime/date inputs in both directions while retaining valid values; its fresh
console and the final navigation console had no errors or warnings.

A 320px probe retains a shared-shell limitation: unchanged `assets/css/app.css`
sets `body { min-width: 320px }`, exceeding the 305px client width when a vertical
scrollbar is present. Calendar controls wrap at that width, but no global-shell
320px layout pass is claimed. The connection action rows also wrap after the
Calendar-specific narrow-screen correction.

Final screenshots are `/tmp/manifold-calendar-browser-{desktop,mobile}-{sunshine,moonlight}-final.png`;
the final text snapshot is `/tmp/manifold-calendar-browser-final-desktop.txt`.
These are local evidence, not committed product assets. The task's test server
and isolated browser tab were stopped after checks; unrelated servers/tabs were
preserved.

## Reproduce the scoped checks

From the project root, enter `devenv shell`, then enter this worktree. Use a
dedicated database; never point these commands at working user data:

```sh
cd .trees/calendar-local-first
export MIX_ENV=test
export TEST_DATABASE_URL="postgres://manifold_dev:manifold_dev@localhost/manifold_calendar_local_first_test?socket_dir=$PGHOST"
mix ecto.create
mix ecto.migrate
mix compile --warnings-as-errors
mix test \
  apps/manifold_calendars/test \
  apps/manifold_connectors/test/manifold/connectors/calendar_connections_test.exs \
  apps/manifold_connectors/test/manifold/connectors/calendar_migration_test.exs \
  apps/manifold_connectors/test/manifold/connectors/calendar_sync \
  apps/manifold_connectors/test/manifold/connectors/dav \
  apps/manifold_connectors/test/manifold/connectors/icloud_test.exs \
  apps/manifold_connectors/test/manifold/connectors/icloud \
  apps/manifold_account_lifecycle/test/manifold/account_lifecycle/icloud_test.exs \
  apps/manifold_web/test/manifold_web/calendar_live_test.exs \
  apps/manifold_web/test/manifold_web/calendar_display_test.exs \
  apps/manifold_web/test/manifold_web/calendar_oauth_controller_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs \
  apps/manifold_web/test/manifold_web/account_icloud_live_test.exs \
  apps/manifold_web/test/manifold_web/icloud_settings_live_test.exs \
  apps/manifold_web/test/manifold_web/external_accounts_web_test.exs
mix assets.build
mix duskmoon_bundler.js.check
git diff --check
```

Check formatting only for the changed/new Elixir source, test and migration
files; a repository-wide formatting rewrite is outside this scope. The final
gate collected those paths with `git ls-files --modified --others
--exclude-standard` and passed them to `mix format --check-formatted`.

For the migration probe, create a new empty database whose URL contains
`calendar_migration_`, set `TEST_DATABASE_URL` to that disposable database and run:

```sh
MIX_ENV=test mix run --no-start scripts/calendar_migration_probe.exs
```

## Preserved failure evidence

The initial audit's three pure probes reproduced incorrect timezone display,
missing recurring occurrences and deleted exceptions without exclusions. Their
successful execution was reproduction evidence, not a product pass; see the
[dated audit](../plans/2026-10-19-calendar-local-first-correction.md#7-验证范围和本次证据).

Implementation red/green logs remain under `/tmp/manifold-calendar-*`. In
particular, the OAuth safety red run had seven failures before the response and
generation/session fences were repaired. Final checks include those regressions.
The late reminder-input probe reproduced `reminders: nil` crashing local create;
the added test covers create/update with eight invalid values, unchanged stored
data/revision, and explicit `[]` clearing. The final 280-test gate includes it.

An earlier setup run encountered stale worktree build metadata and an absent
isolated test database; these were resolved within the worktree/test environment.
Neither setup recovery nor the controlled peers replace real Google/iCloud
acceptance, a full VM restart gate or an operator-reviewed deployment/cutover.

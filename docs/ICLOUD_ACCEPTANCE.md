# iCloud contacts and calendars acceptance

Approved scope: local contact CRUD, independent read-only iCloud contacts and
calendar synchronization, settings/navigation, and one minor release.
Implementation starts from `dfe2412a74596aed2238ee30ee0ba18d5530f298` in an
isolated worktree, preserving unrelated changes in the original checkout.

## Verified behavior

- **PASS:** 68 scoped ExUnit tests for contacts (10), calendars (6), encrypted
  connections, synchronization, DAV parsing/transport, LiveViews, existing
  settings navigation and credential encryption. Seed: `969238`.
- **PASS:** additional default-client protocol integration test exercises DAV
  discovery, vCard projection, unchanged ETags, updates and remote deletion
  through the synchronization/database boundary. Seed: `361241`.
- **PASS:** 39 scoped TLS/ex_ssl compatibility tests. Seed: `285493`.
- **PASS:** controlled actual TCP peers prove DAV verbs/Basic authorization,
  redirect refusal, response limits, absolute timeout/socket cleanup and absence
  of credential-bearing Finch request telemetry.
- **PASS:** failure/lifecycle fixtures cover incomplete snapshot retention,
  independent service commits, retry deadlines, leases, generation fencing,
  read-only imports and isolation of local/other-connection records.
- **PASS:** public Apple contacts/calendar HTTPS PROPFIND requests reach verified
  TLS endpoints and return unauthenticated 401 responses.
- **NOT RUN:** real credentialed Apple synchronization. No real Apple Account
  app-specific password was supplied. Fixtures and unauthenticated connectivity
  do not establish successful account-specific synchronization.

## Build, browser and release evidence

- **PASS:** final feature suite: 68 tests, zero failures (`618655`), plus six
  existing settings-navigation tests, zero failures (`362579`): **74 total**.
  The final suite includes five calendar component-boundary regressions and
  the default-client protocol integration test.
- **PASS:** all changed Elixir/HEEx files formatted; strict development compile.
- **PASS:** JS check (zero errors; two pre-existing unused catch-variable warnings).
- **PASS:** production asset deployment and main/edge release builds, rebuilt
  after the final calendar parser repair.
- **PASS:** isolated packaged main migration/context CRUD and startup HTTP 200
  on `/contacts`, `/calendars`, `/settings/icloud`.
- **PASS:** actual served final JS clears the native password DOM value after
  invalid submission; sanitized error shown with account identifier retained.
- **PASS:** local create/search/edit/delete/confirmation, imported read-only
  contact, calendar timezone/recurrence/details and both themes with persisted
  preference across hard navigation. No browser console errors/warnings.
- **PASS:** 390px mobile viewport has no page overflow and all six navigation
  links remain reachable by scrolling within the appbar. Moonlight Add contact
  contrast measures 12.70:1.
- Browser screenshots retained locally under `tmp/icloud-browser/` (sunshine,
  moonlight, mobile and calendar details; fixtures contain no real credentials).
- Published artifact evidence is recorded in the release notes after completion.
Browser verification uses an isolated fixture database and disabled fake iCloud
connection, without making credentialed Apple requests. Local contacts, imported
read-only data, calendar timezone/recurrence details and both DuskMoon themes
are included. Production main/edge builds are separate from publication proof.

## Supported scope and operational limits

Supported projections: vCard 3.0/4.0 and iCalendar 2.0 VEVENT. Unsupported or
malformed resources fail the collection without removing its stored data.
Recurring event records/metadata are retained; occurrence expansion and calendar
editing are outside this version. Apple synchronization is read-only.

The five-minute schedule queues work on the shared connectors queue; it does
not guarantee a completed synchronization within five minutes. Keep the
connector encryption key stable. See `ICLOUD.md` for setup, migration and
rollback. Rolling back the new migration deletes all new tables, including
local contacts; retain additive tables when rolling back only binaries.

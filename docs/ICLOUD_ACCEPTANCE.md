# iCloud contacts and calendars acceptance

## Configured-account error repairs — 2026-10-11

- Confirmed China-region discovery failures: the global Contacts endpoint
  advertised a nonexistent global shard; the global Calendar endpoint
  advertised a China-region home that the previous URL policy rejected.
  Exact Apple China DAV hosts are now accepted, with one DNS-only regional
  discovery retry using the same deadline.
- Confirmed Calendar discovery also returned two Reminders collections
  supporting VTODO only. Event synchronization now excludes collections
  explicitly lacking VEVENT support; unknown capabilities remain subject to
  normal validation. No parser or complete-snapshot safeguards were relaxed.
- **PASS:** saved-account authenticated discovery and local import through
  repaired modules: **132 contacts**, **79 events**, one address book and five
  event calendars, both service statuses `connected` with saved timestamps.
  An initial transient Apple HTTP502 preserved prior data; the next complete
  read succeeded. Verification permitted only PROPFIND/REPORT/GET and issued
  zero cloud writes.
- Confirmed the independent IMAP SEARCH response included nonexistent UIDs.
  Successful FETCH with no FETCH data now follows the existing not-found
  path, while malformed FETCH remains an error. Body reads use BODY.PEEK[].
- **PASS:** actual Apple IMAP probe reads an existing message and skips stale
  UIDs without exposing contents; provider FLAGS/INTERNALDATE before and after
  the body read are identical.

- **PASS:** final scoped DAV/iCloud/IMAP/provider/synchronization regression
  suite: **136 tests**, zero failures. Includes stale SEARCH UIDs, body PEEK,
  malformed FETCH, strict China DAV URLs, bounded DNS fallback, unsafe
  redirect rejection and calendar component eligibility. Strict compilation,
  changed-file formatting and diff checks passed.

## Account-owned bidirectional implementation — 2026-10-10

Current scope: iCloud configuration in Accounts, local-first Contacts/Calendar
CRUD, asynchronous bidirectional resource synchronization, default-enabled
contact preference, explicit destinations, conflict choices and retained local
data on disconnect. Branch: `codex/account-icloud-sync`, based on v0.5.1.
This section records implementation acceptance before publication. The user
subsequently authorized merge to main, v0.6.0 publication and devenv restart;
publication evidence is recorded separately below.

- **PASS:** final scoped ExUnit suite, **203 tests, zero failures**, seed `468787`:
  Calendars18, Contacts20, DAV/iCloud/connectors80, AccountLifecycle40, selected
  Account/Contact/Calendar/settings LiveViews45. Covers local offline saves,
  transactional intent rollback, explicit destination merge, independent
  ownership/remap races, older acknowledgement versus newer edits, repeated
  property identity rebase, lost responses, conditional conflicts, opt-out,
  capabilities, lifecycle fencing and Account purge isolation.
- **PASS:** invitation resource edit/delete and final-event deletion from mixed
  VEVENT/VTODO resources retain local intentions and issue zero cloud writes.
  Document checks also cover VJOURNAL and unknown component deletion refusal.
- **PASS:** actual TCP peers verify conditional PUT/DELETE headers, UTF8 request
  body/media type and classification of a lost write response. These exercise
  the DAV client/transport contract using controlled peers.
- **PASS:** populated migration acceptance preserves two contacts, two event
  projections/shared resource identities, raw documents and ETags with **zero
  queued uploads**. Evidence database:
  `manifold_icloud_upgrade_1791618216470758`. Legacy local contacts remain
  unassigned; deleting the connection retains local records.
- **PASS:** strict development compilation, formatting of all 45 changed Elixir/
  HEEx files and `git diff --check`.
- **PASS:** asset build and JS check: zero errors, two existing unused catch
  variable warnings. CSS 493 KB and JS 195.8 KB.
- **PASS:** isolated browser fixture on port4395 verifies immediate Contact/event
  saves while iCloud is disabled, native date/time inputs, account selection,
  default Contact sync preference, both sunshine/moonlight themes and connected
  LiveView without console errors/warnings. Contacts/Calendar pages have no
  horizontal overflow at 390px. Account details retain an existing 4px overflow
  caused by the receive-method table; it is outside this change.
- **PASS:** browser destination mapping refuses save without explicit merge
  consent; confirmed merge saves immediately with existing local event IDs and
  records retained while the fake connection is disabled. Imported baseline
  retention is covered by domain/LiveView tests. No console errors/warnings.
- **NOT RUN:** real credentialed Apple account discovery and CRUD. No disposable
  Apple account/app-specific password was supplied. Controlled peers, fixtures
  and local builds do not prove account-specific Apple interoperability.
- **Implementation-stage NOT RUN:** release publication, packaged release
  acceptance and development process restart. These were subsequently authorized
  and completed as recorded in the v0.6.0 section below.

Verification runs through root `devenv shell`, with isolated database
`manifold_icloud_acceptance_test`; only affected apps/test paths are selected:

```sh
mix test apps/manifold_contacts/test apps/manifold_calendars/test \
  apps/manifold_connectors/test/manifold/connectors/dav \
  apps/manifold_connectors/test/manifold/connectors/icloud \
  apps/manifold_connectors/test/manifold/connectors/icloud_test.exs \
  apps/manifold_account_lifecycle/test \
  apps/manifold_web/test/manifold_web/contact_live_test.exs \
  apps/manifold_web/test/manifold_web/calendar_live_test.exs \
  apps/manifold_web/test/manifold_web/icloud_settings_live_test.exs \
  apps/manifold_web/test/manifold_web/account_icloud_live_test.exs \
  apps/manifold_web/test/manifold_web/account_live_test.exs
MIX_ENV=test mix run --no-start apps/manifold_data/test/acceptance/icloud_upgrade.exs
mix compile --warnings-as-errors
mix assets.build
mix duskmoon_bundler.js.check
```

Only generated fixtures are used for acceptance. The development database was
later backed up and migrated during the authorized process restart; no production
database was migrated. Setup/rollback limits are in `ICLOUD.md`.

## Published v0.6.0 and main integration — 2026-10-10

- **PASS:** feature commits fast-forwarded into main; the completed worktree and
  branch were removed. Original root design drafts are retained in a named git
  stash and hash-verified snapshot at
  `tmp/worktree-merge-20261010-account-icloud/`. The implemented documents supersede
  their draft status; no unrelated source edits were absorbed.
- **PASS:** merged-main local acceptance: 203 scoped tests, zero failures, seed
  `438645`; repository format, strict compile, asset build and JS check. The two
  existing JS unused catch-variable warnings remain.
- **PASS:** source CI `38037553296`, full ExUnit `38037553333` (**1,401 tests**, zero
  failures, seed `472723`) and TLS `38037553267` (**46 tests**, zero failures, seed
  `216062`) on source commit `16085c45673278dabe8725845a38e258e843bed9`.
- **PASS:** release workflow
  [38037710921](https://github.com/gsmlg-opt/manifold/actions/runs/38037710921)
  completed Build Release, both Docker image jobs and release-note update.
  Published [v0.6.0](https://github.com/gsmlg-opt/manifold/releases/tag/v0.6.0)
  tag/version commit:`6d15e4f953f8c4932d5d2e8b1ce94342a6e8f84c`.
- **PASS:** downloaded archives match GitHub size and SHA-256:
  main 48,864,407 bytes,
  `a450da1763fc2dc2acac37c99566a13bedd653f05d089a506c354cddfc97aa83`;
  edge 28,465,510 bytes,
  `8a9f1b177ad16cbcc372d57a218bb238faf319de644cf3dd45c82eb2befffffd`.
  Exact active release files and `runtime.exs` match the tag; all 15 main and 4 edge
  application versions are 0.6.0. Main includes iCloud modules/migration002;
  the ingress-only edge excludes them.
- **PASS:** actual downloaded main archive, relocated into an independent
  runtime container, migrates a fresh isolated database, performs Contact/
  Calendar/event CRUD and serves `/contacts`, `/calendars`, legacy settings and
  Account iCloud configuration with HTTP 200. Served CSS/JS return 200 and contain
  the password-clear listener. Owned proof container/database cleanup passes.
- **PASS:** downloaded edge archive migrates its isolated database, uses
  `Manifold.Edge.SMTP` resolver/ingest wiring, serves authenticated status 200 and
  completes SMTP 220/QUIT 221. Owned proof container/database cleanup passes.
- **PASS:** digest-pinned GHCR main/edge images were pulled and their actual
  active release/application versions, required BEAM modules and migration bytes
  verified. Runtime configuration matches the tag. Main digest:
  `sha256:d0bfddd70780e8f02dca3251761f39252c8ec8b302715b91dc555a79e3d92864`;
  edge digest:
  `sha256:2ad220051c0212897ede3e3998d8a539288646e96a9f6a11c80f73e9bbf92b45`.
  OCI revision labels carry the workflow dispatch source `16085c4`, before the
  automated version bump; actual image apps are 0.6.0 and migration/runtime bytes
  independently match tag `6d15e4f`. Identity containers were never started and
  removed after inspection. Runtime/DB checks apply to downloaded archives above;
  they were not repeated for the GHCR images.
- **PASS:** root devenv PostgreSQL and Manifold ready after orderly stop/start;
  migrations001/002 present in `manifold_dev`. Contacts, Calendars, Accounts,
  Account iCloud details and CSS/JS respond 200. The pre-upgrade development dump is
  retained with restrictive permissions at
  `tmp/release-0.6.0/devenv-pre-upgrade.dump`.
  Initial PostgreSQL restart overlapped old smart shutdown and was recovered
  after the old postmaster exited; the final readiness check passes.
- **NOT RUN:** real credentialed Apple discovery/CRUD. This limitation is also
  disclosed in the public release notes. Fixture/archive startup acceptance does
  not establish successful Apple account-specific synchronization.

Detailed local evidence/scripts are under `tmp/release-0.6.0/`, including
`digest-verification.json`, `archive-verification.json`,
`packaged-acceptance-report.json` and `devenv-http-proof.json`. A verifier's initial
incorrect boot filename assumption is retained in `download-failure.json`; the
correct active `start.boot` gate and both runtime gates subsequently pass.
GHCR actual-content identity evidence is in
`ghcr-main-identity-evidence.json` and `ghcr-edge-identity-evidence.json`.

## Historical read-only implementation and releases

The sections below record earlier read-only functionality and publication
evidence. They do not describe the current branch's editable synchronization.

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

## Published v0.4.0 and relocation correction

Release workflow `37963642826` completed successfully, publishing main/edge
archives and both images. Release tag/source: `4571f976988cb1471776ed158b79b990144d9acc`.
Pre-release source CI passed 1,322 tests (`122453`), format/strict compile/JS;
TLS workflow passed 46 tests (`662377`).

Downloaded archives match GitHub sizes and SHA-256:

- Main: 37,945,882 bytes,
  `bf08fc529f905bdcfe1765c0a893ab3dcf5eff9a992270e1cc79b8d63b4d4711`.
- Edge: 28,031,544 bytes,
  `c46d5a81f487ffab45dc3d6a57a015cdd1492f9ed844d088755eb0edc3e0289f`.

All packaged project applications have version 0.4.0. Main includes the new
contexts and migration; edge excludes them. **FAIL:** actual downloaded main
archive relocation/startup HTTP verification returned 500: the build-time
absolute asset manifest path survived relocation. Earlier local startup at the
build path passed and did not prove portability. Migration/context CRUD passed.
The public v0.4.0 release is marked prerelease with this failure disclosed;
its tag and archives have not been rewritten. Do not use its main archive or
image until a correction is published; pin v0.3.0 rather than mutable latest.

**PASS, local correction only:** production runtime now uses the supported
`duskmoon_bundler_runtime` profile override with
`Application.app_dir(:manifold_web, "priv/static/assets")`. A rebuilt main
release copied to an independent directory passed fresh isolated migration,
context CRUD and HTTP 200 for `/contacts`, `/calendars`, `/settings/icloud`.
Strict compile and formatting pass. The user authorized publishing the corrected implementation as **v0.5.0** on
2026-10-10. The public v0.4.0 tag and artifacts remain unchanged; corrected
published artifact/startup verification is required before completion.

## v0.5.0 release candidate

Source correction CI: `37965535415` (format/strict compile/JS), `37965535528`
(full ExUnit suite), and `37965535443` (TLS workflows), all successful.
A relocated local main package passed fresh isolated migration/context CRUD and
HTTP 200 for all three new pages. Publication verification is recorded in the
v0.5.0 release notes and final acceptance checkpoint after actual download.

## v0.5.0 publication acceptance — PASS

- Stable GitHub release: https://github.com/gsmlg-opt/manifold/releases/tag/v0.5.0.
- Release workflow `37966360700`: main/edge archive build, both GHCR images and
  release notes all **PASS**. Latest stable release is v0.5.0.
- Release source/tag: `d841d1e642c6390d12dae1ceab24128c39f78a75`;
  source CI `37966328364`, full tests `37966328367` and TLS `37966328444` pass.
  Workflow source differs only by project version metadata from tested source.
- Main archive: 40,139,560 bytes; SHA-256
  `aa57a1758836e04ea8c50323e9a1f39da03c90730f999451c6da6451393cbb07`.
- Edge archive: 28,227,694 bytes; SHA-256
  `b08d36b3d4a3df17d69cb71cd9d8c29ba12442ed34130cc6914627d45955b71d`.
  Both sizes/digests match GitHub asset metadata. Active start_erl/.rel/.boot/.app
  closures select 0.5.0; main contains the new contexts/sync/migration, edge
  excludes them. Cached archives retain historical 0.4.0 directories; these
  are outside the active 0.5.0 closure and were preserved during verification.
- **PASS:** actual downloaded main archive executed in a compatible Ubuntu
  container at an independent installation path. Fresh isolated PostgreSQL
  migrations, active app versions, local contact CRUD, calendar reads, three
  page HTTP responses and served CSS/JS/password-clear listener all pass.
- **PASS:** actual published main GHCR image executed independently: fresh
  migration/context operations, all 15 project app versions 0.5.0, three pages,
  CSS/JS and password-clear listener. Its runtime configuration matches the tag.
- **PASS:** edge GHCR manifest/config digests, four packaged project app versions
  0.5.0 and runtime configuration matching the tag. Edge runtime startup:
  **NOT RUN**.
- Main OCI index digest:
  `sha256:35b92b472e1ef432b39de67b6e64ecc84e707840c8a7f3701ca934c33093701a`.
- Edge OCI index digest:
  `sha256:26c64e1d9cf236739736fd0a8b22c0eb431c2e2bc36fbbd3cab8cd5698dfd5ca`.
  OCI revision labels identify tested workflow caller `c0e3985`; packaged
  runtime configuration matches the version-bump tag `d841d1e` byte-for-byte.
- **NOT RUN:** real credentialed Apple synchronization; the established
  implementation/browser/fixture boundaries remain unchanged.

Local evidence: `tmp/icloud-release-0.5.0/{digest,archive}-verification.json`,
`tmp/icloud-oci-0.5.0/{main-startup,edge-packaged}-evidence.json`, and the
published archive startup log. Owned preview and verification containers are
stopped; the original working tree and existing development server are retained.
The v0.4.0 prerelease tag and archives remain unchanged and are superseded by
this verified v0.5.0 release. No further release is authorized by this task.

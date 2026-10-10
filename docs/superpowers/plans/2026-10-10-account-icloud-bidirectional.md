# Account iCloud bidirectional synchronization implementation plan

> **For agentic workers:** Use subagent-driven-development for independent scoped
> tasks, with parent integration and review. Steps use checkboxes for tracking.

**Goal:** Account-configured iCloud Contacts/Calendar with local-first CRUD and
durable asynchronous bidirectional synchronization.

**Architecture:** Reuse Account ownership, keep local records independent of
provider collections, and persist resource revisions before DAV writes. One
full ICS resource is one conditional write/conflict unit. Network workers depend
on shared data contracts, with no network calls from domain saves.

**Tech Stack:** Elixir/Ecto/PostgreSQL, Oban, Phoenix LiveView, verified Mint DAV.

## Task 1: Ownership, local models and transactional intents

Files: additive migration in `apps/manifold_data/priv/repo/migrations`, schemas
in `apps/manifold_data/lib/manifold/data/schema`, shared
`apps/manifold_data/lib/manifold/data/sync_state.ex`, Contacts and Calendars
contexts/tests. Data worker owns these files.

- [ ] Establish passing scoped Contacts/Calendars/DAV/iCloud baseline.
- [ ] Add connection Account ownership/default address book; collection
  capabilities; local Calendar; Contact Account/sync preference/revision/deletion;
  CalendarEvent local calendar/resource/revision/deletion; DAVResource durable
  remote baseline, desired/attempted revisions and conflict/outcome state.
- [ ] Migrate existing identities without uploads; remove collection cascade
  dependence of retained local data.
- [ ] Implement transactional local create/update/delete, opt-out suppression,
  Account destination selection and pending intent staging with no network.
- [ ] Add meaningful scoped tests for preference defaults, offline local writes,
  rollback, deletion tombstones, account identity and calendar CRUD.

Contract: `DAVResource` has kind, account_id, connection_id, collection_id, href,
uid, base_raw, etag, desired_revision, acknowledged_revision, status, operation,
sent_revision, sent_raw, sent_etag, remote_raw, remote_etag, last_error, retry_at.
Contact/CalendarEvent reference resource_id; Calendar maps collection_id.
Shared `SyncState` owns transaction-safe intent staging; worker reports exact API
before network integration. Stable UID/href are persisted before dispatch.

## Task 2: Lossless documents and conditional DAV client

Files: `apps/manifold_connectors/lib/manifold/connectors/dav/{document,client}.ex`
and scoped DAV tests. Protocol worker owns these files.

- [ ] Add bounded raw-line/component document editing; preserve untouched groups,
  parameters, unknown properties, VTIMEZONE, alarms and sibling VEVENTs.
- [ ] Implement contact document build/edit and calendar resource build/edit,
  with safe escaping/folding and stable UID.
- [ ] Add conditional `put_resource/6`, `delete_resource/4` and
  `get_resource/3`; forbid write redirects/retries and classify conflict,
  forbidden, throttled, unknown outcome and missing ETag.
- [ ] Discover collection write/component capabilities.
- [ ] Prove document preservation and wire request semantics with scoped tests.

Document API: `contact(raw_or_nil, attrs, uid)` returns `{:ok, raw}` or error;
`event(raw_or_nil, attrs, uid, recurrence_id)` updates a selected component;
`delete_event(raw, uid, recurrence_id)` returns a full resource or empty marker.
Client conditional PUT receives kind and `:create` or observed ETag.

## Task 3: Account settings, resource reconciliation and async workers

Parent owns `icloud.ex`, `icloud/sync.ex`, new outbound worker/reconciliation
modules and their tests; AccountLifecycle integration follows data contracts.

- [ ] Add account attach/adopt/default destination, active-state eligibility,
  legacy assignment state and disconnect retention.
- [ ] Reconcile inbound reads through remote resource baselines rather than
  unconditional overwrite/cascade deletion; preserve pending/paused/conflict.
- [ ] Persist immutable attempted body/revision before network dispatch; serialize
  resource operations and acknowledge only sent revisions.
- [ ] Recover unknown outcomes by reading the same href; conditional retry only
  against unchanged baseline; preserve conflict versions.
- [ ] Poll durable intents and integrate Account disable/purge generation fences.
- [ ] Test concurrent save acknowledgements, crashes/outages, 412, opt-out,
  partial reads and lifecycle races with controlled transport.

## Task 4: Account UI, local editing and conflict resolution

Web worker follows Tasks 1/3 contracts, owning only scoped web LiveViews,
templates/routes/tests. Existing DuskMoon design conventions apply.

- [ ] Put iCloud configuration and adoption in Account settings, expose service
  switches/destinations/status/manual sync; retire standalone configuration.
- [ ] Contact Account selector, default-checked sync preference and visible
  pending/paused/conflict/error states.
- [ ] Local calendars/events create/edit/delete with explicit series/component
  operations and read-only source handling.
- [ ] Conflict actions choose local or remote with renewed ETag protection.
- [ ] Run scoped LiveView checks and both-theme/browser verification where available.

## Task 5: Review, documentation and completion

- [ ] Review each worker diff against approved scope and integration contracts.
- [ ] Update `docs/ICLOUD.md`, `docs/ICLOUD_ACCEPTANCE.md` and feature skill entry.
- [ ] Run scoped affected tests through root `devenv shell`, changed-file format,
  strict compile, and required asset checks. Serialize database test runs.
- [ ] Record exact PASS/FAIL/NOT RUN evidence; credentialed Apple tests remain
  NOT RUN without securely supplied test credentials.
- [ ] Finish reviewable branch. No new publication is scheduled by this plan.

Execution command from root:

```sh
devenv shell -- bash -c 'cd .trees/account-icloud-sync && mix test apps/manifold_contacts/test apps/manifold_calendars/test apps/manifold_connectors/test/manifold/connectors/dav apps/manifold_connectors/test/manifold/connectors/icloud'
```

Expected: all scoped tests pass. Later checks add only affected AccountLifecycle
and web tests. Out-of-scope failures are reported without unrelated repair.

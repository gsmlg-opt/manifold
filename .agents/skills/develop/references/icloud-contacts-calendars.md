# Account-owned iCloud Contacts and Calendar

- Date: 2026-10-10; implemented on `codex/account-icloud-sync` from v0.5.1.
- Integrated into main and published as v0.6.0; feature worktree removed.
  Release workflow 38037710921, source CI (1,401 tests + 46 TLS tests), relocated
  main/edge archive startup, GHCR identity and devenv restart proof are in acceptance.
- Approved design: `docs/superpowers/specs/2026-10-10-account-icloud-bidirectional-design.md`.
- Plan: `docs/superpowers/plans/2026-10-10-account-icloud-bidirectional.md`.
- Operator/acceptance: `docs/ICLOUD.md`, `docs/ICLOUD_ACCEPTANCE.md`.
- Scope: iCloud only; Account settings, local-first bidirectional Contacts/Calendar.
  Contact `sync_to_icloud` defaults true. The user subsequently authorized merging
  to main, publishing v0.6.0 and restarting devenv on 2026-10-10.

## Module ownership

- `manifold_data`: Account ownership, local Calendar, Contact/CalendarEvent revisions
  and tombstones, DAVResource baselines/immutable attempts; migration002 preserves
  legacy IDs/raw/ETags with zero uploads. `SyncState` locks Account→connection→resource
  and stages durable intents in the domain save transaction, with no network or
  dependency on connectors. Oban is a wakeup, not the source of pending state.
- `manifold_contacts`: local CRUD/copy/search/Account selection and default preference;
  opt-out retains suppression binding. Bound ownership changes require copies.
- `manifold_calendars`: local calendar/event CRUD/mapping, full-resource revision
  staging; component or whole-series deletion; date/time validation. Default
  queries hide tombstones; `include_deleted_conflicts:true` exposes conflict actions.
  Explicit same-Account destination adoption merges imported events without new
  imported revisions; source unbound drafts alone are enrolled. Account, resource
  and Calendar locks precede mapping identity rechecks.
- `manifold_connectors`: Account-owned credentials/adoption/destinations, discovery
  capabilities, complete inbound reconciliation and conditional outbound writes.
  DAV Document patches complete raw data, preserving groups/params/photo/timezones,
  alarms/recurrence/siblings. Client uses create `If-None-Match:*`, write/delete strong
  ETag `If-Match`; no write redirect/replay. Outbound reconciles immutable sent
  revisions and unknown outcomes before retry; explicit local/remote conflict choice.
  `sent_contact_values` preserves attempted property IDs for rebasing newer local
  repeated-property edits after acknowledgement. ORGANIZER/ATTENDEE resources
  refuse cloud editing/deletion to avoid unsupported scheduling.
- `manifold_account_lifecycle`: existing connector-stage delegation integrates iCloud
  generation quiescing, job drain and bounded local purge. No remote purge deletes.
- `manifold_web`: Account ICloudComponent settings; legacy SettingsLive assignment;
  Contact and Calendar local forms/status/copy/conflict actions using DuskMoon.

## Constraints and follow-ups

One connection per Account. No automatic ownership guessing or mass upload of
unassigned records. Disable/purge fence dispatch/commits; an admitted HTTP request
can finish. Disconnect retains local records and removes credentials/targets.
Reconnect never silently reuses old bindings for a new Apple identity.

No Google, remote container management, occurrence expansion, arbitrary recurrence
editing, future splits or invitation/RSVP/scheduling. Strict document comparison
accepts folding/order and managed revision timestamps; ambiguous provider edits
stay conflicted. Never serialize imported resources from projections alone.
Whole-resource deletion refuses unrelated VTODO/VJOURNAL/unknown components;
Account purge finds event tombstones even after local Calendar deletion.

Crypto uses connection-specific AAD; public preloads/jobs omit credentials.
DAV validates Apple HTTPS hosts and uses bounded direct Mint with verified OTP TLS.
Complete validated collection results are necessary for deletes/checkpoints.
Respect per-resource retries plus connection-wide throttling/auth admission.

Run scoped tests centrally through root devenv with a disposable isolated database.
See acceptance for exact evidence. Real credentialed Apple writes remain NOT RUN
unless secure disposable test-account credentials are available. Existing release
history and archive verification remain in the historical acceptance sections;
v0.5.0/v0.5.1 publication remains historical evidence. Current publication
authorization is the user's explicit merge/release/restart request.

## Configured-account repairs — 2026-10-11

- DAV URL policy allows exact `contacts`, `caldav`, and numbered service shards
  under `icloud.com` and `icloud.com.cn`, retaining verified HTTPS on port443.
  Global Contacts discovery can advertise a nonexistent global shard for a
  China-region account. Preserve the safe `:nxdomain` classification through
  Mint/Transport/Client and restart read-only discovery once at the China root,
  with the original deadline. Other errors do not trigger a regional retry.
- Calendar discovery may advertise a China-region home directly from the global
  root. Resolve it under the same strict URL policy. Skip collections explicitly
  advertising no VEVENT support (including VTODO-only Reminders), retaining
  unknown capability collections for normal fail-closed validation. Writes retain their existing
  conditional request and redirect/replay restrictions.
- The independent IMAP receiver can encounter stale UIDs in iCloud SEARCH
  results: a tagged successful FETCH with no FETCH response means `:not_found`.
  Existing sync handling records a local deleted remote-message marker and
  continues/checkpoints the page. Malformed FETCH data still fails parsing.
  Fetch bodies with `BODY.PEEK[]` so synchronization preserves provider flags.
- Regression tests live in DAV regional discovery/transport, IMAP protocol, and
  IMAP synchronization tests. Account-specific read/import verification is
  recorded in `docs/ICLOUD_ACCEPTANCE.md`; no schema changes are required.

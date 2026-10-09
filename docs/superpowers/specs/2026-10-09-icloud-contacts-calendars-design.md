# iCloud contacts and calendars — proposed v0.4.0 design

Date: 2026-10-09
Status: approved by user on 2026-10-10; implementation in progress.

## Goal

Provide useful local contact management, automatically import/synchronize iCloud
contacts, read iCloud calendar data, and publish one verified version before
stopping. Publication is authorized by the original request.

## Recommended behavior

- Contacts: list, search, details, and create/edit/delete local contacts. Support
  names, multiple email addresses and phone numbers, organization, postal
  addresses, and notes. Imported contacts display their iCloud connection and
  address book and are read-only. Do not automatically merge matching emails.
- iCloud settings: add an Apple Account identifier and app-specific password;
  choose contacts and/or calendars; verify discovery and enqueue the initial
  sync. Support multiple connections, manual sync, credential replacement,
  disable/enable, and disconnect with confirmation. Show each service's last
  successful sync and sanitized failure/reconnect status.
- Contacts synchronization is one-way from iCloud. Local contacts remain local.
  Cloud updates and deletions become visible locally after successful sync.
- Calendars: list discovered calendars and their stored event records, with
  event details, start/end, all-day status, location, description, timezone,
  recurrence rules and exceptions. Retain original iCalendar data for fidelity.
  Recurring records are explicitly marked; this version does not claim to
  expand recurring occurrences into a full calendar grid.
- Both selected services synchronize on connection and every five minutes,
  with a manual refresh action. A service failure does not erase successful
  data from the other service.
- Disconnect removes the connection's credentials and imported records only;
  disabling retains records and stops synchronization. Neither changes iCloud.

## Alternatives considered

1. **Recommended:** CardDAV/CalDAV with an app-specific password and read-only
   cloud synchronization. Fits the requested read access, works independently
   of email, and avoids write conflicts.
2. Contacts first, calendars in a later release: smaller delivery, but does not
   fulfill the calendar-reading request in this version.
3. Bidirectional contact/calendar editing: broader usefulness but requires
   remote write authorization, conflict policy, and substantially more protocol
   and UI work than the requested reading and import.

Apple documents app-specific passwords as a supported fallback for third-party
apps at https://support.apple.com/en-us/121539. The settings help must explain
how to generate and revoke one; never request the primary Apple password.

## Architecture and ownership

- `manifold_data`: shared contact, calendar, DAV resource/collection, and iCloud
  connection schemas plus migrations in `priv/repo/migrations`.
- New `manifold_contacts`: contact validation, local CRUD, search, and imported
  contact projection/query contracts.
- New `manifold_calendars`: calendar and event query/projection contracts.
- `manifold_connectors`: independent iCloud connection context, encrypted
  credentials, DAV discovery/transport/parsing, synchronization and jobs.
  Existing mail-provider behavior remains mailbox-specific.
- `manifold_web`: `/contacts`, `/calendars`, `/settings/icloud`, navigation and
  LiveView tests, using existing DuskMoon components and theme tokens.
- Root release/application wiring and `config/config.exs`: include the new
  contexts in the main release and schedule a dedicated iCloud poll job on
  the existing connectors queue. The edge release has no DAV credentials/jobs.
- No REST/GraphQL expansion or mail-compose integration in this version.

The existing application uses trusted full-instance access, without users or
tenant authentication. iCloud connections are instance-owned and independent
of local mailboxes. No new login/tenant system is implied by this feature.

## Data and synchronization correctness

Resources are uniquely identified by connection, collection, and normalized
resource href. Preserve remote UID and ETag without treating UID/email as a
global identity. Retain raw vCard/iCalendar text and supported projections.

Use server synchronization tokens when supported, with ETag enumeration and
changed-resource reads as the fallback. Repeated synchronization is idempotent.
Only commit deletions/checkpoints after a complete validated collection result.
Malformed, truncated, unauthorized, or incomplete responses retain previous
records/checkpoints. Unsupported records must not silently become deletions.

Jobs carry a connection generation; credential replacement, disabling, or
disconnecting invalidates older work. Recheck the generation under a database
lock before committing data/status/checkpoints. Uniqueness and serialization
prevent overlapping work for a connection, including manual/cron races.

## Security and limits

Reuse connector AES-256-GCM with connection-specific authenticated context.
Passwords never enter job arguments, returned views, logs, telemetry or release
artifacts; clear the settings form after submission and filter secret params.

Use the existing Req client and verified HTTPS. Validate discovery hrefs and
redirect destinations before sending Basic credentials: explicit Apple DAV
hosts/shards, HTTPS port 443, no userinfo, fragments or arbitrary destinations.
Disable automatic redirects/retries and implement only bounded validated
discovery redirects. Bound request deadlines, response sizes, collection and
resource counts, and parsing complexity. Use a namespace-aware XML parser with
external entities/DTD disabled; do not allocate atoms from remote XML names.

Remote operations are limited to read/discovery methods. Authentication failure
requires reconnection; throttling/transient failures use bounded retries and
honor Retry-After. Sanitized errors must not expose credentials or remote bodies.

## Authorized file scope

New contact/calendar apps; new schemas and migrations under manifold_data; new
iCloud/DAV modules and tests under manifold_connectors; related web routes,
navigation, LiveViews and tests; necessary app dependencies and lock entries;
root release wiring and Oban configuration; README/product design and
`.agents/skills/develop/references/icloud-contacts-calendars.md`.

Preserve pre-existing uncommitted dependency/UI changes. Review any prerequisite
dependency overlap separately; do not silently include unrelated work in the
feature commit/release. If using a worktree, create it under this project's
`.trees/` directory. Do not switch the application HTTP client as part of DAV.

## Acceptance and release gates

1. Scoped data/context tests prove local CRUD, validation, search, identity
   isolation, imported-record read-only behavior, and disconnect isolation.
2. DAV fixtures prove discovery, XML namespace handling, folded/escaped vCards,
   multiple values, all-day/timezone/recurring ICS records, ETags, sync tokens,
   remote additions/updates/deletions, and repeat-sync idempotence.
3. Fault/race tests prove partial-sync retention, credential secrecy, redirect
   rejection, request/response limits, throttling, and lifecycle generation
   fencing. Controlled real HTTP traffic verifies transport behavior.
4. Scoped LiveView/navigation tests and browser checks prove connection setup,
   empty/loading/error states, contacts workflows, calendar reading, and both
   existing themes. Build frontend assets after UI changes.
5. Run formatting and strict compilation plus scoped affected tests. Do not
   repair unrelated failures or widen tests without authorization.
6. Real Apple-account access is a separate credentialed gate. Never label fake
   DAV or local traffic as actual iCloud verification. Request secure settings
   entry when needed; do not request credentials in chat.
7. Release `v0.4.0` through the existing release workflow after review of the
   final diff and passing required gates. Verify GitHub tag/release, both release
   archives, Docker publication, migration/startup behavior and committed source
   parity. Record any unrun credentialed gate honestly in release evidence.
8. After publishing this one version and reporting evidence, stop this goal.

# iCloud contacts and calendars

- Date: 2026-10-10.
- Status: implemented; v0.4.0 published as prerelease after portability failure.
  Local runtime asset correction verified; correction publication pending decision.
- Approved scope: local contacts, automatic read-only iCloud contact import/sync,
  calendar reading, then one release and stop.
- Design: `docs/superpowers/specs/2026-10-09-icloud-contacts-calendars-design.md`.
- Acceptance: `docs/ICLOUD_ACCEPTANCE.md`; operator guide: `docs/ICLOUD.md`.

## Module ownership

- `manifold_data`: ICloudConnection, DAVCollection, Contact, CalendarEvent;
  migration `20261010000100` adds four tables with isolated cascading imports.
- `manifold_contacts`: validated local CRUD/search/pagination and read-only imports.
- `manifold_calendars`: calendar/event queries and retained recurrence/timezone data.
- `manifold_connectors`: encrypted credentials, independent lifecycle, bounded
  CardDAV/CalDAV discovery/read, snapshot/delta reconciliation, leases/generation
  fencing, SyncICloud and five-minute PollICloud jobs on the connectors queue.
- `manifold_web`: `/contacts`, `/calendars`, `/settings/icloud`, source labels,
  local forms, secret clearing, both themes and responsive navigation.
- Root main release includes both new contexts; edge remains ingress-only.

## Implementation boundaries

Connections belong to the trusted local instance, independently of mailboxes.
Passwords use Crypto with connection-specific AAD and are absent from public
preloads/jobs. The DAV Req adapter uses direct Mint HTTP/1 rather than Finch to
avoid Basic credentials in Finch request telemetry. Every destination is
allowlisted HTTPS Apple DAV before dispatch; OTP verifies peer and hostname.
Saxy parses namespace-qualified DAV XML with limits and no DTD loading.

Only complete collection results can apply deletions/checkpoints. Services
commit independently. Invalid/unsupported sync tokens fall back to bounded
ETag enumeration. Generation plus owner/expiry leases fence stale jobs after
credential replacement, disable or disconnect. Retry deadlines apply to manual
and automatic synchronization. Local contacts are never uploaded or removed.

## Validation and operator follow-up

Scoped domain/protocol/LiveView/security and ex_ssl compatibility tests pass;
see acceptance for exact counts, seeds, browser and release evidence. Real
credentialed Apple verification remains NOT RUN and requires secure entry in
Settings. Do not treat fixtures or unauthenticated TLS as that proof.
Dependencies changed narrowly: unavailable historical ex_ssl Git pin replaced
by validated exact Hex 0.17.1, Saxy 1.6.1 added, existing Mint declared directly.
Keep encryption key stable and apply additive migration before main startup.
Migration rollback deletes local contacts too; binary rollback can retain tables.

## Release correction boundary

Actual downloaded archive checksums/version/module wiring passed, but relocation
exposed a build-machine absolute asset outdir and HTTP 500. Runtime uses the
supported :duskmoon_bundler_runtime :manifold_web outdir override computed by
Application.app_dir; this is application configuration, not an upstream bug.
Corrected local relocated startup/migration passes. Keep public v0.4.0 marked
prerelease until a correction publication is chosen; no tag/artifact rewrite
has been performed. Record actual published verification independently.

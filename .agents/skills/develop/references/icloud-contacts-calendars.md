# iCloud contacts and calendars

- Date: 2026-10-10.
- Status: released and verified as v0.5.0.
  v0.4.0 remains prerelease after its portability failure.
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
prerelease; its tag/artifacts remain unchanged. The user authorized corrected
v0.5.0 publication. Verify downloaded packages and relocated startup independently.

## Verified v0.5.0 release

Workflow37966360700 succeeded; stable tag/source d841d1e, tested workflow
caller c0e3985. Downloaded main/edge sizes and SHA-256 match GitHub. Active
archive closures are0.5.0 (older cached directories are inactive). Actual
relocated main archive and published main image pass fresh migrations/context
CRUD and three pages/CSS/JS. Edge image metadata and versions pass; edge boot
NOT_RUN. Real credentialed Apple synchronization remains NOT_RUN. See acceptance
and release notes for exact digests. Release and final documentation are merged
into main; the original local maintenance changes were subsequently committed
for the separately authorized v0.5.1 maintenance release. Verification
evidence is retained in the root checkout under `tmp/icloud*`, and pre-merge
local files are backed up under `tmp/worktree-merge-preserved-*`.
The original feature/release scope concluded with v0.5.0.

## DAV timeout classification correction

The subsequent maintenance CI run `37970230361`, seed `12335`, exposed a
stalled-peer race: passive Mint receive can return
`%Mint.TransportError{reason: :timeout}` before the outer adapter Task deadline.
The adapter preserves that receive timeout as `:timeout`; other transport
failures retain their generic classification. This is application error mapping,
not an upstream Mint defect.

`transport_test.exs` deterministically exercises the internal timeout using real
loopback traffic and call/return tracing. It suspends the outer requester after
Mint receive begins, observes the socket timeout and worker termination, then
resumes the requester. No sleeps or mocked transport errors determine the
ordering. The test cleans up tracing, suspended tasks and socket ownership;
a peer closing without an HTTP response still returns `:transport_failure`.
Before the adapter correction the new test failed with the CI error; afterward
the transport file passes 8 tests and the scoped DAV directory passes 30 tests,
both with seed `12335`. Changed Elixir files are formatted.

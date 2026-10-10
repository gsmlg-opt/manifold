# Account-owned iCloud contacts and calendars

Date: 2026-10-10
Status: user-approved design; implemented; scoped acceptance complete (203 tests, zero failures).

## Confirmed scope

Configure Contacts and Calendar inside an Account. Implement iCloud only.
Both services synchronize in both directions: local creation, edits and deletion
must be reflected in iCloud, and remote changes must be reflected locally.
Writes commit locally first; remote synchronization runs asynchronously.
Every contact has `sync_to_icloud`, defaulting to true.
In the user's earlier message, “local accounts and calendar” is interpreted as
local Contacts and Calendar, consistently with the surrounding request.

This supersedes the independent-connection, read-only behavior in the previous
iCloud design. The completed v0.5.0/v0.5.1 releases remain historical evidence;
the user subsequently authorized merge to main, v0.6.0 publication and a devenv
process restart on 2026-10-10.

## Recommended ownership and configuration

Reuse the existing local Account as the ownership boundary. Its details page
contains an iCloud connection, separate Contacts/Calendar switches, service
status and manual synchronization. Adding iCloud requires choosing an existing
Account or explicitly creating a local Account through the existing account
form. An Apple ID is a provider credential, not an automatically created email
route. Apple ID need not equal the local Account's address.

Each Account has at most one active iCloud connection in this version. Multiple
Accounts may use different connections. Contacts belong to an optional Account;
no Account means a purely local contact. Local calendars belong to an optional
Account and can be mapped to discovered iCloud calendars. Existing mail receive
and send configuration remains available alongside these services.

Choose a discovered writable address book as the Account's default contact
destination. New contacts use their selected Account and its default destination.
Calendar configuration maps a local calendar to a discovered remote calendar;
events inherit this mapping. This version does not create or delete remote
address books/calendars, implement Google, or add multi-provider fan-out.

Alternatives considered: a separate cloud-account registry would duplicate the
existing Account UI/lifecycle; putting cloud credentials directly on each contact
would lose Account-level configuration. An Account-owned connection is the
smallest change that meets the requested behavior.

## Local-first contacts

The contact form exposes Account and “Sync to iCloud”, checked by default.
Saving validates and commits the contact immediately. In the same database
transaction, advance its local revision and persist a synchronization intent
when a configured destination is available. Network failure cannot roll back a
successful local save. No network request runs in the form/save transaction.

The preference and operational state are separate: true with no configured
Account/destination means “waiting for configuration”, not “synchronized”.
Account service switches pause synchronization without changing the preference.
New Account-owned contacts waiting for configuration become eligible when the
destination is selected. Existing unassigned contacts are not mass-uploaded:
assigning them to an Account explicitly enrolls them when the flag is true.
No automatic deduplication by email, name or UID across Accounts.

Turning the preference off stops subsequent inbound/outbound synchronization
for that contact, cancels unsent intents, and retains both local and remote data.
Keep the remote mapping so a poll cannot recreate it as a duplicate. A request
already dispatched may finish; report and reconcile its outcome without issuing
new writes. Turning synchronization back on compares both sides against their
last shared revision; divergence is a conflict, never a silent overwrite.

Deleting an enrolled contact hides it immediately and retains a durable tombstone
until remote deletion succeeds or its conflict is resolved. Deleting a contact
whose preference is off deletes only the local view and retains a suppression
mapping so the remote contact is not reimported. A never-uploaded create followed
by deletion can be cancelled locally unless its remote outcome is unknown.

Changing an enrolled contact's Account/destination must not silently move or
delete remote data. Offer an explicit local-copy action into the new Account;
the original remote mapping remains attached to the original contact.

## Local calendars and event editing

The current calendar context only reads imported events. Add local calendars and
local event create/edit/delete, with Account/destination selection and immediate
local save. A mapped calendar synchronizes events asynchronously; an unmapped
calendar remains local. Calendar synchronization is controlled at calendar and
Account levels; a separate event preference is not required by this scope.

Support summary, description, location, start/end, all-day and timezone values.
Preserve DATE, UTC, floating-time and TZID semantics. Recurring imports retain
their master/exception components. The UI explicitly distinguishes editing an
existing component from deleting an entire series. This version does not add
recurrence expansion, arbitrary recurrence-rule editing, splitting future
occurrences, invitation sending, RSVP, or attendee scheduling.

Operations use the full remote ICS resource as their synchronization unit.
Editing one VEVENT preserves sibling events, exceptions, alarms, VTIMEZONE and
unknown properties. Deleting an exception removes that component through a PUT;
it must not DELETE a resource containing the series. A generated occurrence that
has no stored component is not presented as an independently editable event.
Explicit whole-series deletion updates the resource when siblings remain, and
DELETE is allowed only when the complete resource is to be removed.

Discover read/write capabilities per collection/resource. Read-only shared
sources show their limitation and offer a local-copy action. No apparent remote
save success is shown when the server denies the operation.

## Data and durable synchronization

Keep stable local Contact/Calendar/Event identities independently of remote
collections. A resource binding stores Account/connection, collection/href,
UID, complete remote raw document, observed ETag, shared base revision, and
synchronization state. CalendarEvent rows are projections of a resource;
several rows may share one binding. Contact `sync_to_icloud` is the source of
truth for its preference rather than a second independently editable flag.

Persist intents/tombstones and immutable dispatched payloads in the database.
Oban workers process them; a recovery poll finds durable work missed by a wakeup.
Coalesce unsent edits, serialize operations for each resource, and acknowledge
only the revision actually sent. A save during an in-flight request remains
pending after the older request succeeds. Restarting cannot lose local writes.
Domain save paths depend on shared data contracts, not connector network code;
do not introduce circular umbrella dependencies.

Inbound synchronization updates the remote shadow first. Only clean, enrolled
records accept projection updates/deletions. Pending edits, tombstones, conflicts
and disabled preferences prevent overwriting local state. Missing collections
must no longer cascade-delete local drafts or retained contacts/events. Apply
remote deletions/checkpoints only after complete, validated collection results.

Use stable UID/href generated before the first create dispatch:

- Create: conditional PUT with `If-None-Match: *`.
- Update/delete: conditional PUT/DELETE with the observed strong `If-Match` ETag.
- HTTP 412 or divergent versions: retain local draft, remote version and base;
  expose “Use local” and “Use iCloud”. Resolving uses the current remote ETag and
  can conflict again; never make an unconditional overwrite.
- Timeout/transport failure: persist “outcome unknown” and GET the same resource
  before another write. Reconcile server-normalized payloads against the sent
  revision. Confirm a delete by absence; retry only when the base is unchanged.
  A changed resource becomes a conflict, avoiding duplicate creates or deletion
  of another client's new version.

Errors retain local work and show pending, syncing, synchronized, paused,
conflict, waiting for configuration, or failed/reconnect-required status.
Honor throttling and retry deadlines. A forbidden collection write is distinct
from an authentication failure.

## Document preservation and security

Existing parsers are read projections and discard groups/parameter structure;
do not serialize their projections back over an imported document. Add bounded
lossless document editing that preserves untouched raw properties/components,
Apple grouped labels, photos, unknown attributes, recurrence and timezone data.
Track repeated-property identity so removing an email/phone/address affects the
selected property. Escape and fold newly written content correctly with UTF-8
safe line folding. Keep new-document generation separate from imported editing.

Reuse connection-specific encrypted credentials and bounded verified DAV
transport. Validate Apple HTTPS destinations before dispatch, suppress secrets
from logs/jobs/UI, use the correct vCard/calendar Content-Type, and prohibit
automatic write redirect/retry replay. Missing trustworthy ETag or unsupported
document editing prevents unsafe dispatch and leaves local work visible.

## Lifecycle and migration

Account disable/purge, service disable and credential replacement fence queued
dispatch and local commits using Account state, connection generation and leases.
Stopping cannot undo a request already sent; retain/reconcile that outcome rather
than claim no remote side effect. Account purge/disconnection never translates
to remote contact/calendar deletion.

Disconnection removes credentials and retains local records without an active
cloud target. Account purge follows the existing explicit local-deletion flow
and cancels cloud work. Reconnecting to a different Apple identity must not reuse
old bindings or silently upload old content into the new identity.

Use additive migrations. Preserve existing connection IDs, encrypted AAD,
collection IDs, contact/event IDs and remote identities. Existing standalone
connections are marked “Account assignment required” and pause until explicitly
bound in Account settings. Do not guess ownership from Apple ID/email or impose
new Apple ID uniqueness. Legacy imported contacts default to sync enabled but
become clean bindings, so migration/adoption does not upload them. Existing local
contacts remain unassigned and are not uploaded merely because an Account is
configured. The old settings URL leads to the Account assignment/configuration
surface rather than a second independent configuration path.

## Ownership, scope and acceptance

- `manifold_data`: additive ownership/resource/intent migrations and schemas.
- `manifold_accounts`: existing Account contracts/configuration ownership.
- `manifold_contacts`, `manifold_calendars`: local CRUD/revisions and data queries.
- `manifold_connectors`: DAV document editing, conditional writes, inbound/outbound
  reconciliation, capabilities, connection settings, polling and workers.
- `manifold_account_lifecycle`: iCloud quiescing and local purge integration.
- `manifold_web`: Account setup, forms, source filters, sync status and conflicts,
  using existing DuskMoon design tokens/components.
- Related scoped tests, operator/acceptance docs, and the develop feature entry.

Acceptance must prove local save with the remote offline, default preference,
opt-out/re-enable, migration without uploads, durable restart recovery, concurrent
save acknowledgement, complete-resource preservation, conditional writes,
unknown-result recovery, conflicts, partial-read retention, suppression against
reimport, source permissions and lifecycle races. Scoped LiveView tests cover
Account setup, Contact preference, Calendar CRUD and conflict resolution.
Controlled actual HTTP tests verify wire headers and write fault outcomes.
Real credentialed Apple CRUD/synchronization is a separate gate using disposable
test data; report NOT RUN if credentials are unavailable. No fixture test can
stand in for that evidence. Run only affected tests and checks; preserve unrelated
work. Implementation worktrees belong under this repository's `.trees/`.

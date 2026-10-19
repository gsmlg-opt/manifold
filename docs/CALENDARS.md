# Local calendars and Google/iCloud synchronization

Calendars work without a mailbox Account, provider connection or network. A local
Calendar and its events keep their IDs when a synchronization target is added,
paused, detached or reauthorized. One calendar can synchronize bidirectionally
with Google Calendar and iCloud Calendar at the same time.

This guide describes the implementation on `codex/calendar-local-first`, based
on `5a6825f`. It is not a deployment or credentialed-provider acceptance record.
See the [implementation evidence](superpowers/implementation/calendar-validation.md).

## Using the workspace

Open `/calendars`, add a local calendar and create events. Select which calendars
are visible independently from the default destination for new events. Month and
agenda views expand RRULE/RDATE/EXDATE and detached exceptions within the selected
range. Set a viewing timezone to place timed events on the correct local day;
all-day dates remain dates. Floating times follow the viewing timezone.

Event forms preserve date, UTC, floating and TZID meanings. Recurrence properties
may contain complete parameterized lines, for example
`EXDATE;TZID=America/New_York:20261020T100000`. Expansion failures and limits are
shown explicitly. Edit/delete one occurrence by its original slot, or choose the
whole series. Copying an occurrence preserves its moved time; copying a series
preserves rules, exclusions and exceptions under a new identity. A copy into a
calendar with active synchronization targets requires explicit upload confirmation.

Read-only imported events require an independent copy before local editing.
Invitation/RSVP scheduling and future-series splits are outside the supported
editing scope. Unknown provider properties remain in the retained ICS/JSON.
Relative display alarms map to canonical popup reminders. Google explicit popup
and email reminders are retained; iCloud email/audio/absolute/repeated alarms and
inherited Google defaults are marked as limited when they cannot be represented
faithfully. A limited target does not imply the other target failed.

## Connect providers and choose targets

Use **Calendar connections** on the Calendar page:

- **Google:** configure the shared Google client at Settings → OAuth, enable the
  Calendar API in Google Cloud and register the configured callback exactly.
  Start the Calendar authorization from this page. It requests Calendar scopes
  separately from Gmail; a mailbox receive/send method is unnecessary. The
  returned Google subject verifies the identity. The saved callback can use
  `/connectors/gmail/callback`; Calendar login state routes it to the Calendar
  handler. Direct `/calendar-connections/google/callback` is also supported when
  registered. The current Calendar flow requires a reachable callback.
- **iCloud:** enter the Apple login and an app-specific password. Discovery
  verifies the authenticated CalDAV principal. Calendar credentials are separate
  from the Account-owned Contacts connection, even for the same Apple login.

Discover calendars, select an existing remote calendar, and review **Confirm
initial synchronization**. Select historical local events to upload and remote
resources to import. Imports can propagate to the other already enrolled targets;
the preview shows that impact. Similar UID/title/time values do not merge records.
Use an explicit identity claim only when the records represent the same event.
Differing claimed versions remain a conflict. Confirmations and previews persist
across page reloads. Newly created local events enroll on confirmed targets.

Each target owns its checkpoint, raw resources, desired/acknowledged revisions,
immutable attempts and conflicts. Accepted inbound changes pass through the local
model before reaching other targets. Echoes do not add revisions. A late response
only acknowledges the revisions that were sent, preserving newer edits/deletions.
Unknown submissions are read and reconciled before another write is considered.

## Pause, detach, disconnect and delete

| Action | Result |
| --- | --- |
| Hide a calendar | Changes the displayed calendars only |
| Pause one target | Stops new requests and retains its mapping, pending changes and unknown attempts; other targets continue |
| Resume | Reads/reconciles retained state before dispatching remaining work |
| Detach | Archives the target and suppression history; retains local data and remote data; new changes are not enrolled there |
| Explicit re-enrollment | Reuses target identity and unresolved evidence, with a fresh import/upload preview; unselected history stays suppressed |
| Remove Calendar authorization | Shows affected bindings, removes only that connection's usable credential, retains local data and unknown requests |
| Reauthorize the same verified identity | Reuses the connection and mappings; detached targets still require explicit re-enrollment |
| Delete a local calendar | Archives the local calendar and detaches its targets; does not issue remote deletes |
| Delete an enrolled event/occurrence/series | Saves a local tombstone and independent conditional deletion intents for the selected scope |
| Delete a mailbox Account | Leaves local calendars, events and Calendar connections intact |

Already admitted requests can finish after pause/disconnect. Their outcomes must
remain available for reconciliation. Missing containers, revoked permissions,
authentication errors and incomplete pagination never imply event deletion.
Target cards and event details show pending, limited, conflict, failed and unknown
states. Resolve conflicts from the local/remote/baseline preview, which also lists
the other targets affected by the accepted choice.

## Upgrade and activation

1. Back up PostgreSQL and `MANIFOLD_CONNECTOR_ENCRYPTION_KEY` together. Stop the
   old application instances or quiesce their Calendar dispatch and wait for their
   admitted requests to finish or be recorded. Never run old and new Calendar
   writers concurrently against the same resources. The new `SyncICloud` path
   admits Contacts only, so Contacts can continue after the cutover.
2. Apply `20261019000100`, `20261019000200` and `20261019000300` using the normal
   release migration procedure. Do this before starting the new writer. Migrations
   retain Calendar/Event IDs, old fields/raw resources/ETags, dirty revisions,
   tombstones, conflicts, unknown attempts and the original encryption context.
   They perform no provider requests. Legacy resource counters are retained as
   evidence and are never invented into per-component acknowledgments.
3. Migrated connections and targets start paused and require identity review.
   On the Calendar target, choose **Review existing synchronization**. The review
   verifies the identity, hydrates semantic baselines from retained raw data and
   performs a read-only comparison. It displays retained/missing mappings and
   unresolved attempts. No provider write is sent by review.
4. Review the exact report, then activate that target. Activation re-fetches the
   report and checks identity generation and local revisions; any change requires
   a fresh preview. Old unbound drafts are not automatically uploaded. Missing
   identities whose old associations were already lost remain local and need an
   explicit new enrollment.

Keep additive tables and immutable attempt history for rollback. After any new
write was dispatched, restoring an older database and restarting the old writer
can duplicate or overwrite cloud data. Stop dispatch, retain all new request and
response records, read/reconcile the provider state and make a reviewed forward
repair. A backup cannot undo a request already accepted remotely.

`scripts/calendar_migration_probe.exs` exercises the upgrade in an empty disposable
database whose URL contains `calendar_migration_`. It creates the old schema and
fixtures, applies all new migrations and checks retained data and zero HTTP calls.
Run it with `MIX_ENV=test mix run --no-start`; never use a working user database.

Real Google/iCloud authorization and joint disposable-data writes remain a
separate acceptance gate. Controlled localhost HTTP results do not establish
real provider compatibility.

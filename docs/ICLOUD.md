# iCloud Contacts and Calendar

Contacts and Calendar are configured inside a local Account. Local changes save
immediately; background jobs synchronize them with iCloud in both directions.
This feature supports iCloud only. Access to the web endpoint remains trusted
full-instance access.

## Configure an Account

1. Enable Apple two-factor authentication and generate an app-specific password
   at https://account.apple.com/ (https://support.apple.com/en-us/102654).
2. Open **Settings → Accounts**, create or select a local Account, and configure
   **iCloud Contacts and Calendar** on its details page. The local Account address
   and Apple login can differ. Existing Account mailbox/routing semantics apply.
3. Enter the Apple login and app-specific password, and select Contacts and/or
   Calendar. Each Account has at most one connection.
4. Wait for discovery, then select the default writable address book. Contacts
   wait locally until this destination is configured. Map local calendars to
   discovered iCloud calendars on the Calendars page.

Passwords use connection-specific encryption with
`MANIFOLD_CONNECTOR_ENCRYPTION_KEY`. Keep the key stable. Credentials never belong
in jobs, logs or source control; the password form clears after submission.
Replace a revoked app-specific password in the Account. Changing Apple identity
requires disconnection and a new connection; retained bindings are not silently
uploaded into that identity.

The old **Settings → iCloud** page lists connections and links to their Accounts.
Legacy connections require explicit assignment to an Account before syncing.
Assignment preserves record/connection IDs, encryption AAD, raw documents and
ETags. It does not upload migrated records or infer ownership from email.

## Contacts

`/contacts` supports local create/edit/delete, search, multiple email/phone/address
values and explicit local copies. Choose an Account and **Sync to iCloud**
(default enabled). Unassigned contacts remain local; enabling the flag alone
never chooses an upload destination. Newly configured destinations enroll only
explicitly Account-owned drafts.

Turning the flag off pauses both inbound application and outbound writes while
retaining both copies and their binding. Deleting an opted-out contact hides the
local record and retains suppression metadata so polling does not recreate it.
Re-enabling compares the retained baseline; divergent changes require a choice.
Changing a bound contact's Account requires an explicit local copy.

## Calendars and events

`/calendars` supports local calendar and event create/edit/delete. An unmapped
calendar remains local. Map to an existing discovered iCloud collection for
asynchronous event synchronization. Remote calendar/address-book container
creation, renaming and deletion are outside this feature. Deleting a local
calendar requires its visible events and deletion conflicts to be resolved.

Discovery creates a local calendar for each imported destination. To map an
existing local calendar to that destination, explicitly confirm **Merge the
existing local calendar for this iCloud destination**. Imported events move into
the selected calendar and the replaced local calendar is removed. Event/resource
identities, raw documents and acknowledged baselines remain intact; only the
selected calendar's unbound local events are enrolled for upload. Both calendars
must belong to the same Account. A calendar with existing resource bindings
cannot be remapped; use explicit local copies instead.

Event forms support summary, description, location, start/end, all-day and
original timezone. DATE, UTC, floating and TZID representations are preserved.
Imported recurrence masters and exceptions remain stored components; occurrences
are not expanded. Edit a selected component or explicitly delete a whole series.
Removing an exception updates its full ICS resource without deleting its master.
Unedited sibling events, alarms, timezones and unknown properties are retained.
Recurrence-rule editing, future splits, invitations and RSVP are not supported.
Read-only collections offer a local copy and refuse unsupported writes.
Resources containing ORGANIZER or ATTENDEE remain readable, but cloud edits and
deletes are refused to avoid implicit scheduling. Local edits/intents remain
stored with an explanatory sync error. Make a local copy to edit independently.
Deleting the last event also refuses whole-resource deletion when unrelated
VTODO, VJOURNAL or unknown components remain, preserving their cloud data.

## Async synchronization and conflicts

Local save transactions persist durable revision/intention state. Oban jobs wake
sync workers; the five-minute poll also recovers work after restarts. A queued
operation does not guarantee completion within five minutes. Account pages show
service status; contact/event details show pending, paused, uncertain, failed or
conflicted resource status. Deletion conflicts remain accessible in their lists.

Creates use stable UID/href and `If-None-Match: *`; updates/deletes use strong
`If-Match` ETags. A lost response is reconciled by reading the same href before
retrying. Acknowledging an older write never clears a newer local edit.
Repeated contact properties retain their original parameters and groups. If a
server response changes property positions, newer local edits rebase their
property identities against the acknowledged document without replacing values.
Normalization permits folding, property order and provider-maintained revision
metadata while retaining unknown content in comparison; other changes produce
an explicit conflict. **Use local** retries conditionally against the observed
remote version; **Use iCloud** accepts the remote version or deletion. Another
remote edit can conflict again.

Complete validated collection results are required before applying remote
deletions or checkpoints. Partial/malformed responses preserve previous data.
Services commit independently; authentication failures stop affected writes and
throttling pauses connection admission until the stored deadline. Missing
collections retain local drafts and bindings with writes unavailable.

## Lifecycle and security

Disabling an Account/connection/service stops new dispatch and retains local
records/intents. Disconnect removes credentials/active targets and keeps local
contacts, calendars and events. Explicit Account purge deletes only its local
data through the durable purge workflow, never issuing cloud deletes. Other
Accounts and unassigned local contacts remain intact.

Generation/lease checks fence stale jobs and acknowledgements. An already
admitted HTTP request may finish after disable/disconnect; these actions cannot
retract a remote request.

DAV destinations are verified HTTPS Apple hosts/shards on port443. Direct bounded
Mint HTTP/1 transport verifies TLS peer/hostname and avoids credential-bearing
Finch telemetry. Writes never automatically redirect or replay. Unsupported
editing and missing strong ETags retain local work instead of overwriting.

## Upgrade

Back up PostgreSQL and the connector encryption key. Apply additive migrations
`20261010000100` and `20261010000200` before starting the main application:

```sh
devenv shell -- mix ecto.migrate
```

For packaged main installations:

```sh
bin/manifold eval 'Application.put_env(:manifold_data, :oban_enabled, false); Application.ensure_all_started(:manifold_data); Ecto.Migrator.with_repo(Manifold.Repo, fn repo -> Ecto.Migrator.run(repo, :up, all: true) end)'
```

The new migration creates local calendars/resource state and backfills imported
baselines with zero outbound revisions/jobs. Legacy local contacts remain
unassigned. Main includes these services; the ingress-only edge does not.
Retain additive tables for binary rollback; schema rollback can destroy local
records/state. Export/back up data before explicit migration rollback.

Verification evidence and the separate credentialed Apple gate are in
`docs/ICLOUD_ACCEPTANCE.md`.

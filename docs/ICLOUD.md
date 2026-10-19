# iCloud Contacts

Contacts are configured inside a local Account. Local changes save immediately;
background jobs synchronize them with iCloud in both directions. Contacts support
iCloud only. Access to the web endpoint remains trusted full-instance access.

Calendars and events are independent of Accounts and can synchronize with iCloud
and Google simultaneously. Their connections, migration, recurrence behavior and
operations are documented in [Calendars](CALENDARS.md).

## Configure an Account

1. Enable Apple two-factor authentication and generate an app-specific password
   at https://account.apple.com/ (https://support.apple.com/en-us/102654).
2. Open **Settings → Accounts**, create or select a local Account, and configure
   **iCloud Contacts** on its details page. The local Account address and Apple
   login can differ. Existing Account mailbox/routing semantics apply.
3. Enter the Apple login and app-specific password, and enable Contacts. Each
   Account has at most one Contacts connection.
4. Wait for discovery, then select the default writable address book. Contacts
   wait locally until this destination is configured.

Passwords use connection-specific encryption with
`MANIFOLD_CONNECTOR_ENCRYPTION_KEY`. Keep the key stable. Credentials never belong
in jobs, logs or source control; the password form clears after submission.
Replace a revoked Contacts app-specific password in the Account. Changing Apple
identity requires disconnection and a new connection; retained bindings are not
silently uploaded into that identity.

The old **Settings → iCloud** page lists Contacts connections and links to their
Accounts. Legacy Contacts connections require explicit assignment to an Account
before syncing. Assignment preserves record/connection IDs, encryption AAD, raw
documents and ETags. It does not upload migrated records or infer ownership from email.

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

Open `/calendars` to create local calendars without an Account or cloud connection.
Add an iCloud Calendar connection there using an Apple login and app-specific
password. These credentials and their lifecycle are separate from the Contacts
connection, even when both use the same Apple login.

Calendar discovery and initial synchronization require a reviewed import/upload
selection. They preserve local Calendar/Event identities; matching UID, title or
time does not automatically merge events. The workspace expands recurrence rules,
exclusions and moved/deleted exceptions within a bounded range. Each Google or
iCloud target keeps independent pending changes, acknowledgments and conflicts.
See [Calendars](CALENDARS.md) for setup, editing capabilities, target controls and
the upgrade procedure for existing Calendar mappings.

## Async synchronization and conflicts

Local save transactions persist durable revision/intention state. Oban jobs wake
sync workers; the five-minute poll also recovers work after restarts. A queued
operation does not guarantee completion within five minutes. Account pages show
Contacts status; contact details show pending, paused, uncertain, failed or
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
Contacts synchronization commits independently of Calendar targets.
Authentication failures stop affected writes and throttling pauses connection
admission until the stored deadline. Missing collections retain local drafts and
bindings with writes unavailable.

## Lifecycle and security

Disabling an Account or its Contacts connection stops new Contacts dispatch and
retains local records/intents. Disconnect removes Contacts credentials/active
targets and keeps local contacts. Explicit Account purge deletes its Account-owned
local data through the durable purge workflow, never issuing cloud deletes. Other
Accounts and unassigned local contacts remain intact. These Account operations
preserve independent calendars, events and Calendar connections. Calendar target
pause, detach and authorization removal follow the separate
[Calendar lifecycle](CALENDARS.md#pause-detach-disconnect-and-delete).

Generation/lease checks fence stale jobs and acknowledgements. An already
admitted HTTP request may finish after disable/disconnect; these actions cannot
retract a remote request.

DAV destinations are verified HTTPS Apple hosts/shards on port 443, including
`icloud.com.cn` for China-region accounts. Discovery starts at the global service;
when its host or advertised shard does not exist in DNS, it retries discovery
once at the China-region service using the same deadline. Authentication,
throttling and other transport errors do not switch regions. Calendar discovery
excludes collections that explicitly advertise no `VEVENT` support, such as
iCloud Reminders (`VTODO`). Unknown capability sets retain normal validation.
DAV uses `Manifold.Core.HTTPClient` and the native `http_fetch` HTTP/1 transport
with bounded headers/bodies, TLS peer/hostname verification and OTP TLS by default.
HTTP telemetry is disabled; writes never automatically redirect or replay.
Unsupported editing and missing strong ETags retain local work instead of overwriting.

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

Those original iCloud migrations created local resource state and backfilled
imported baselines with zero outbound revisions/jobs. Legacy local contacts remain
unassigned. Existing Calendar data additionally requires the migrations and
reviewed activation in [Calendars](CALENDARS.md#upgrade-and-activation).
Main includes these services; the ingress-only edge does not.
Retain additive tables for binary rollback; schema rollback can destroy local
records/state. Export/back up data before explicit migration rollback.

Historical verification evidence and the separate credentialed Apple gate are in
[iCloud acceptance](ICLOUD_ACCEPTANCE.md). They describe the dated implementation
and do not establish acceptance of the independent Calendar path; current
controlled-test evidence and remaining real-provider gates are linked from
[Calendars](CALENDARS.md).

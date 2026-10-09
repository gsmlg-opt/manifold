# iCloud contacts and calendars

Manifold supports local contact management and read-only iCloud synchronization.
Connections are independent of mailboxes and belong to the trusted local
installation. Access to the web endpoint remains full-instance access.

## Connect

1. Enable two-factor authentication on your Apple Account.
2. At https://account.apple.com/, choose **Sign-In and Security → App-Specific
   Passwords** and generate a password for Manifold. Use this app-specific
   password rather than your primary Apple password. Apple documents the flow
   at https://support.apple.com/en-us/102654.
3. Open **Settings → iCloud**, enter the Apple Account identifier (email or phone)
   and the generated password, select Contacts and/or Calendars, and connect.
4. The initial background job verifies access, discovers address books/calendars,
   and imports records. Watch the independent service status and successful-sync
   timestamps. Incorrect/revoked credentials require replacement in Settings.

Passwords are encrypted with the existing `MANIFOLD_CONNECTOR_ENCRYPTION_KEY`.
Keep that key stable when upgrading or restoring a backup. No Apple credential
belongs in environment files, job arguments, logs or source control. The form
clears its password field after saving, including invalid submissions.

## Contacts and calendar reading

`/contacts` lists, searches, and displays both local and imported contacts.
Create/edit/delete local contacts, including multiple emails, phones, postal
addresses, names, organization and notes. Imported contacts are read-only and
labelled with their account and address-book source. Matching email addresses
or UIDs from different books/connections are not automatically merged.

`/calendars` lists discovered calendars and stored event records. Event details
include start/end, all-day state, original timezone, location, description,
recurrence rules, exclusions and recurrence exceptions. Original vCard and
iCalendar text is retained in the database. This version lists stored event
records without expanding recurring occurrences into a month/week calendar.
Floating times remain floating; timezone values are not fabricated or converted.
Supported projections are vCard 3.0/4.0 and iCalendar 2.0 VEVENT. Unsupported or
malformed resource results retain prior collection data and checkpoint and
report a failure; they never silently erase existing records.

## Synchronization and lifecycle

Enabled connections synchronize on setup and every five minutes using Oban's
connectors queue. **Sync now** queues a refresh; concurrent queued/running work
is not duplicated. CardDAV and CalDAV only perform discovery/read operations.
Remote additions, edits and deletions appear after a complete successful sync.
Local contacts are never uploaded or removed by an iCloud synchronization.

DAV sync tokens are used when supported. Invalid tokens or unsupported sync
reports fall back to complete ETag enumeration and changed-resource reads.
Incomplete/error/truncated results retain prior data/checkpoints. Each service
commits independently, so calendar errors do not erase successful contacts and
vice versa. Rate limits retain data and defer both manual and automatic retries
until the stored retry deadline.

**Disable** retains imported data and stops synchronization. Enabling queues
fresh work. Changing credentials/services invalidates old jobs. **Disconnect**
requires confirmation and removes that connection's credentials, books,
contacts and calendar records; it retains local contacts and other connections.
Neither action modifies Apple's data.

All destinations must be verified HTTPS Apple DAV hosts/shards on port 443.
Discovery redirects are manually bounded and validated before credentials are
sent. The DAV Req adapter uses fresh Mint HTTP/1 connections with OTP peer and
hostname verification, avoiding credential-bearing Finch request telemetry.
Network deadlines, header/body/resource limits, generation fencing and leased
synchronization bound work and prevent stale jobs from committing after
credential changes or disconnection.

## Upgrade and rollback

Back up PostgreSQL and the connector encryption key before upgrading. Apply
migration `20261010000100` using the existing main-release migration procedure
(or `devenv shell -- mix ecto.migrate` in development). It adds
`icloud_connections`, `dav_collections`, `contacts`, and `calendar_events`.
The main release includes contacts/calendars contexts and the DAV poll job;
the ingress-only edge release does not run these services.

For a release installation, run before starting the new main release:

```sh
bin/manifold eval 'Application.put_env(:manifold_data, :oban_enabled, false); Application.ensure_all_started(:manifold_data); Ecto.Migrator.with_repo(Manifold.Repo, fn repo -> Ecto.Migrator.run(repo, :up, all: true) end)'
```

Retain the additive tables when rolling back application binaries. Rolling back
this migration drops **all new tables and local contacts**, not just imported
records. Stop synchronization and export/back up required data before an
explicit migration rollback; a binary rollback does not require this deletion.

## Verification boundary

Automated fixtures, controlled real HTTP peers, migration/startup checks and
browser checks are documented in `docs/ICLOUD_ACCEPTANCE.md`. Actual Apple
accounts require a separate secure settings entry; no real Apple password was
provided during implementation. Unauthenticated HTTPS DAV discovery proves
connectivity/certificate verification only, not credentialed synchronization.

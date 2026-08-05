# IMAP Account Connector Design

Date: 2026-08-05

## Goal

Let Manifold behave like a mail client when no mailbox exists yet: the primary
empty-state action is **Add account**, and users can connect a third-party
mailbox over **IMAP** (username/password) so mail is pulled into Manifold for
reading.

POP3, outbound SMTP for the user account, folder mirroring, and write-back are
out of scope for this revision.

## Product decisions

| Decision | Choice |
| --- | --- |
| Entry point | Extend **Add account** (`/settings/accounts/new`) with an IMAP path |
| Sync mode | Read-only pull into local inbox (same spirit as Gmail/Microsoft) |
| Protocols | IMAP only; POP3 deferred |
| Auth | Username + password (or app password); encrypted at rest; SSL/TLS or STARTTLS |
| Local mailbox | Auto-derive/create from the IMAP email address; user never picks a mailbox |
| Domains | Hidden in UI; auto-create/reuse `domains` + `mailboxes` under the hood |
| Empty state CTA | Primary **Add account**; local hosted-mailbox creation is secondary |

## Approach

Extend `manifold_connectors` with `provider = "imap"` rather than a parallel
IMAP application or a one-off fetcher. Reuse:

- `connector_accounts` / sync cursors / remote message tracking
- Oban `sync_account` + `poll_accounts`
- `Manifold.Ingest.import_external/3` and the existing spool → projection pipeline
- Settings account list (Sync / Disconnect)

## Architecture

```text
Web (Add account IMAP form)
  -> Connectors.create_imap_account/1
       ensure domain + mailbox (Accounts)
       insert connector_accounts (provider=imap)
       insert connector_imap_settings
       insert connector_credentials (secret_kind=password)
       enqueue Sync
  -> Connectors.Sync.run/2
       decrypt password, IMAP login
       SELECT INBOX, UID bootstrap/incremental pages
       fetch RFC822 -> Ingest.import_external
  -> Mail projection (mailbox_entries / messages)
```

### Provider boundary

The current `Manifold.Connectors.Provider` behaviour assumes OAuth. Split
responsibilities:

- **Shared sync surface:** `initial_cursors/4`, `sync_page/4`, `fetch_raw/4`
- **OAuth providers (gmail, microsoft):** `exchange_code`, `refresh_token`,
  `identity` via access token
- **IMAP provider:** `authenticate` (password session) + `identity`; no OAuth
  callbacks

`Sync.run/2` branches on credential `secret_kind`:

- `oauth` → existing refresh/access token path
- `password` → decrypt password, pass session/auth material into the IMAP adapter

### Auto mailbox binding

On successful IMAP account creation from `email_address = local@domain`:

1. Normalize domain; if no matching `domains.normalized_domain`, insert an active
   domain row (UI never shows this as “hosted SMTP domain” setup).
2. If no matching mailbox under that domain, create it with default folders.
3. Create the connector account bound to that mailbox.
4. Navigate the user to the mail UI for that mailbox.

If the email already has an active connector account of any provider, reject
with a clear conflict error.

Domain auto-creation does not enable or imply local SMTP acceptance for that
domain beyond whatever existing inbound rules already require; IMAP import uses
the external import path, not SMTP RCPT identity fabrication.

## Data model

### `connector_accounts`

- Allow `provider = "imap"` alongside `gmail` / `microsoft`.
- `provider_account_id` is a stable key such as `imap:<normalized-email>`.
- `email_address` stores the user-facing address.

### New `connector_imap_settings`

One row per IMAP external account:

| Field | Notes |
| --- | --- |
| `external_account_id` | FK, unique |
| `host` | IMAP hostname |
| `port` | Default `993` for SSL |
| `tls_mode` | `ssl` or `starttls` |
| `username` | Defaults to email address; editable |
| `mailbox_path` | Default `INBOX` (only folder synced in v1) |

### `connector_credentials`

Extend for password secrets without breaking OAuth rows:

| Field | Notes |
| --- | --- |
| `secret_kind` | `oauth` (default for existing rows) or `password` |
| OAuth columns | Required when `secret_kind = oauth` (current behavior) |
| `password_ciphertext` | New nullable binary; required when `secret_kind = password`; OAuth refresh may be null in that case |

Use the existing connectors AES-256-GCM envelope pattern, with associated data
binding account id and purpose (`imap_password`). Never log plaintext passwords.

### `connector_sync_cursors`

- `scope` = `INBOX` (or configured `mailbox_path`)
- Cursor metadata stores IMAP `UIDVALIDITY` and the last processed UID (or
  equivalent committed high-water mark)
- On `UIDVALIDITY` change: reset cursor and re-bootstrap; do not delete already
  projected local mail; rely on remote-id / ingest dedupe

### Remote message ids

`provider_message_id` = `imap:<uidvalidity>:<uid>` (or an equivalent stable
encoding) recorded in `connector_remote_messages`.

## User flows

### Empty state (`/` with no mailboxes)

- Primary CTA: **Add account** → `/settings/accounts/new`
- Copy oriented to a client: connect an email account to start receiving mail
- Local hosted mailbox creation remains available from settings / `/mailboxes`,
  not as the primary empty-state path

### Add account wizard

1. Account type:
   - Cloud account (Gmail / Microsoft) — existing OAuth + mailbox selection flow
   - **IMAP account** — new path
2. IMAP form (no mailbox picker):
   - Email address
   - Username (prefilled from email)
   - Password / app password
   - Host, port (default 993), TLS mode (`ssl` default, or `starttls`)
   - **Test connection** (LOGIN + SELECT configured mailbox); failure blocks save
3. On success: persist as above, enqueue first sync, redirect to mail for the
   auto-created/reused mailbox

Back/Cancel behave like the existing wizard: no persistent writes until a
successful save after a passing connection test.

### Accounts list

IMAP accounts appear beside cloud accounts with status and last sync. Actions:

- **Sync** — enqueue `sync_account` when status allows
- **Disconnect** — same semantics as today: mark disconnected, clear secrets /
  stop sync, **retain** locally projected mail

## Sync semantics

1. Authenticate with decrypted password over TLS (`ssl` or `starttls`).
2. `SELECT` the configured mailbox path (default `INBOX`).
3. Bootstrap: ascending UID pages with a bounded page size; `FETCH` full RFC822
   bytes; import via `Ingest.import_external`.
4. Incremental: search/fetch `UID last_uid+1:*`.
5. Ignore remote read/delete state for v1 (no write-back, no tombstone mirroring).
6. Scheduling: include IMAP accounts in existing poll cron and manual sync.

Import uses `source_kind = "provider_import"` through the existing external
import pipeline (not SMTP envelope fabrication). A distinct `imap_import` label
is deferred unless audit requirements force it later.

### Error handling

| Class | Examples | Behavior |
| --- | --- | --- |
| `:temporary` | timeout, network blip | snooze / retry; may surface as `failed` briefly |
| `:reconnect` | bad password, auth rejected | `reconnect_required`; stop sync until credentials updated |
| `:permanent` | disconnected account, unrecoverable config | cancel / stop sync |

Connection-test failures stay on the form and do not create account rows.

TLS certificate verification is on by default; “ignore certificate errors” is
not a default option in v1.

## Out of scope (v1)

- POP3
- IMAP OAuth2 / XOAUTH2
- Multi-folder sync or folder mapping UI
- Local → remote write-back (read, delete, move, flags)
- Per-account outbound SMTP submission
- Changing managed outbound (Resend/etc.) behavior
- Showing Domains as part of the IMAP client onboarding

## Testing

### Unit / context

- IMAP settings and password credential changesets
- Ensure-domain / ensure-mailbox from email (create, reuse, conflict)
- Cursor bootstrap, incremental advance, UIDVALIDITY reset
- `Sync.run` password branch does not call OAuth refresh

### Adapter fakes

- Fake IMAP adapter covering login success/failure, SELECT, UID paging, FETCH
- Integration: create IMAP account → sync job → message appears in mailbox

### LiveView

- Empty-state primary CTA routes to add-account
- Wizard offers IMAP; IMAP path has no mailbox selection step
- Failed test connection does not persist; success lists the account
- Existing Gmail/Microsoft wizard still works

### Explicitly not required for v1

Live network IMAP against public providers, POP3, multi-folder, write-back, or
user SMTP send.

## Follow-ups (non-blocking)

- POP3 provider
- Folder mapping beyond INBOX
- Optional SMTP send settings paired with IMAP accounts
- Credential update UI when status is `reconnect_required`
- ADR amendment noting IMAP as an accepted connector transport after
  ADR 0007’s earlier deferral

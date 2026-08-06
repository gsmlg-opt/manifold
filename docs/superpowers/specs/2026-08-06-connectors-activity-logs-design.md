# Connectors Activity Logs Design

Date: 2026-08-06

## Goal

Make IMAP (and related connector) **authentication and sync failures visible**
to operators and account owners. Today, connection-test errors stay on the form
and sync failures are easy to miss in generic logs. This revision adds a
per-account **Activity** surface backed by `:telemetry` emission, append-only
JSONL files, and a Settings LiveView reader.

Password, token, and ciphertext must never appear in activity files or UI.

## Product decisions

| Decision | Choice |
| --- | --- |
| Signal source | Emit at IMAP / Sync boundaries via `:telemetry` |
| Persistence | Append-only JSON Lines files under a configurable directory |
| UI entry | From `/settings/accounts` → **Activity** → `/settings/accounts/:id/activity` |
| Scope | Per-account only; no cross-account log browser in v1 |
| Real-time | Manual refresh; no LiveView PubSub push in v1 |
| Retention | 14 days by default (`:activity_log_retention_days`) |
| Pre-create failures | Stay on form `imap_error` + `Logger`; no activity file without `account_id` |

## Approach

Emit domain events from IMAP and Sync call sites → a Connectors Application
handler appends JSONL → Settings Activity LiveView reads files for one account
and date.

This matches the elixir-observability pattern of **domain emit at the boundary**
and a **handler at the application edge** that owns side effects (disk I/O),
without coupling Sync/IMAP adapters to file paths.

```text
IMAP / Sync (emit :telemetry stop events)
  -> Connectors.ActivityLog.Handler (attached at Application start)
       append JSONL under log/connectors/<account_id>/YYYY-MM-DD.log
  -> Settings LiveView Activity page
       Connectors.list_activity_dates / Connectors.read_activity
```

## Architecture

### Telemetry attachment

Attach the activity-log handler when the Connectors application starts
(alongside any existing telemetry setup). Handler is responsible for:

1. Filtering events of interest (v1 list below)
2. Skipping writes when `account_id` is missing
3. Ensuring the account day directory exists (`File.mkdir_p/1`)
4. Appending one JSON object per line
5. Applying retention (delete files older than configured days)

### Event names (v1)

| Event | When |
| --- | --- |
| `[:manifold, :connectors, :imap, :connect, :stop]` | TCP/TLS connect finished |
| `[:manifold, :connectors, :imap, :auth, :stop]` | LOGIN / authenticate finished |
| `[:manifold, :connectors, :imap, :select, :stop]` | SELECT mailbox finished |
| `[:manifold, :connectors, :sync, :stop]` | Sync run finished (page or full run summary) |

Use `:stop` span events so duration is available as a measurement.

### Measurements

| Key | Events | Notes |
| --- | --- | --- |
| `duration_ms` | all | Integer milliseconds for the span |
| `message_count` | `:sync` only | Messages processed in the run/page |
| `page_count` | `:sync` only | Pages completed (optional if single-page summary) |

### Metadata

Include when known; omit rather than invent:

| Key | Notes |
| --- | --- |
| `account_id` | Required to write; UUID of `connector_accounts` |
| `host` | IMAP hostname |
| `port` | Integer |
| `tls_mode` | `ssl` or `starttls` |
| `username` | For auth-related events only; never password |
| `mailbox_path` | e.g. `INBOX` |
| `uidvalidity` | When relevant to select/sync |
| `provider` | e.g. `"imap"` |
| `result` | `:ok` or `:error` (or string equivalents in JSON) |
| `error_code` | Stable atom/string when `result` is error |
| `error_message` | Safe human-readable summary; no secrets |

**Never** include password, app password, OAuth token, refresh token, or
ciphertext fields in measurements or metadata.

### File layout

Default directory (configurable):

```text
log/connectors/<account_id>/YYYY-MM-DD.log
```

Config under `:manifold_connectors`:

| Key | Default | Purpose |
| --- | --- | --- |
| `:activity_log_dir` | `"log/connectors"` (relative to app cwd / release root as used by other logs) | Root for per-account day files |
| `:activity_log_retention_days` | `14` | Delete files with date older than cutoff |

Format: **JSON Lines** (one JSON object per line). Each line is a self-contained
activity entry including event name, timestamp (ISO-8601 UTC), measurements, and
metadata.

Write rules:

- Only write when `account_id` is present and valid
- `File.mkdir_p/1` the account directory before append
- Connection-test / pre-create failures (no account row yet) stay on the form
  `imap_error` and standard `Logger`; they do **not** create activity files

### Public API

```elixir
Connectors.list_activity_dates(account_id) :: [Date.t()]
Connectors.read_activity(account_id, date, limit \\ 200) :: {:ok, [entry]} | {:error, reason}
```

Behavior:

- Validate `account_id` as a UUID path segment; reject traversal (`..`, `/`, `\`)
- `list_activity_dates/1` returns available log dates for that account (newest
  first or ascending—UI date picker may sort either way; prefer descending)
- `read_activity/3` reads the last `limit` lines of the day file (default 200),
  newest first in the returned list; skip malformed JSON lines rather than fail
  the whole read
- Missing file → `{:ok, []}` (empty day), not a hard error, so the UI can show
  empty state

### Settings UI

Route: `/settings/accounts/:id/activity`

- Reachable from the accounts list via an **Activity** action/link per account
- Date picker defaulting to **today**; options from `list_activity_dates/1`
  (and today even if empty)
- Reverse-chronological event list for the selected day
- **Refresh** control reloads from disk (no PubSub subscription in v1)
- Empty state when the day has no entries

## User flows

1. User opens **Settings → Accounts**
2. Chooses **Activity** on an IMAP (or other) connector account
3. Sees today’s events (connect / auth / select / sync) with result and safe
   error text on failures
4. Optionally picks another date and/or hits Refresh

Operators diagnosing `reconnect_required` or sync failures use Activity before
diving into server logs.

## Out of scope (v1)

- Per-message fetch/import log lines
- Dual-write to the database
- Real-time LiveView push / PubSub
- Secrets or credentials in files or UI
- Cross-account activity browser or global search
- Changing form-level connection-test error UX beyond current `imap_error`

## Testing

### Handler / storage

- Successful emit with `account_id` appends a JSONL line under the expected path
- Emit without `account_id` skips write
- Path traversal / non-UUID `account_id` rejected by read/list APIs
- Retention deletes files older than configured days
- Bad JSON lines skipped on read; valid neighbors still returned

### Integration (Fake IMAP)

- Auth/connect failure after account exists produces a failure summary entry
- Successful sync produces a `:sync` stop entry with counts when applicable

### LiveView

- Activity page loads for a valid account id
- Date picker and refresh show expected empty / populated states
- Invalid account id / unauthorized access follows existing settings auth rules

## Follow-ups (non-blocking)

- PubSub or LiveView streams for live activity
- Structured error taxonomy shared with Oban sync status
- Optional DB mirror for long-term audit
- Activity for Gmail/Microsoft OAuth reconnect paths using the same file schema

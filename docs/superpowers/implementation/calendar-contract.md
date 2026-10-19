# Calendar implementation contract

Approved scope: [correction plan](../plans/2026-10-19-calendar-local-first-correction.md).
User authorized implementation on 2026-10-19. Existing local IDs are retained.

## Shared data contract

All schemas below are `Manifold.Data.Schema.*`, UUID primary keys, microsecond UTC
timestamps. Statuses/directions are strings. Projection keys and revision-vector
event IDs are strings. Secrets use Crypto with an explicit stored context.

- `CalendarConnection`: provider (`google`/`icloud`), remote_identity (nullable until
  verified), identity_verified_at, display_name, credential_context,
  encrypted_credentials (redacted binary), scopes (string array), expires_at,
  status (`active`/`paused`/`reconnect_required`), generation (default 1),
  legacy_connection_id (UUID, evidence only), provider_metadata (map).
- `CalendarBinding`: calendar_id (nullable), connection_id, remote_calendar_id,
  name, direction (`bidirectional`/`inbound`), capabilities (map), state
  (`preview`/`active`/`paused`/`detached`/`unavailable`), generation (default 1),
  checkpoint (map), enrollment_manifest (map), lease_owner, lease_expires_at,
  suppressed_at, legacy_collection_id (UUID), last_error, synced_at.
- `CalendarSyncResource`: binding_id, remote_resource_id, href, base_raw (text),
  etag, remote_raw (text), remote_etag, remote_presence
  (`unknown`/`present`/`deleted`), status (`pending`/`synced`/`conflict`/`uncertain`/
  `failed`/`limited`), provider_metadata (map), retry_at, last_error,
  legacy_resource_id (UUID), legacy_snapshot (map).
- `CalendarEventBinding`: binding_id, event_id, resource_id, remote_component_key,
  desired_revision, acknowledged_revision, base_projection (map),
  projection_fields (string array), projection_version (default 1),
  conflict (map, nullable), state (`enrolled`/`suppressed`/`limited`), last_error.
- `CalendarSyncAttempt`: resource_id, connection_generation, binding_generation,
  operation (`upsert`/`delete`), destination, payload, precondition (map),
  component_revisions (map), sent_projections (map), state
  (`prepared`/`dispatched`/`uncertain`/`succeeded`/`failed`/`conflict`),
  response_etag, response_raw, last_error, dispatched_at, completed_at,
  legacy_snapshot (map). Request fields immutable once inserted. Unique unresolved
  attempt per resource. Legacy attempts have EMPTY component vectors: preserve
  old sent revision as evidence, never infer current event revisions.

Existing `Calendar` gains `deleted_at`, `viewing_timezone` (default Etc/UTC).
Existing Event gains `series_id`, `recurrence_dates`, `recurrence_timezone`,
`time_kind` (`date`/`utc`/`floating`/`tzid`), `read_only`, `reminders` (array of
string-key maps with method popup/email and nonnegative minutes). Reminder
coverage limitations remain explicit; absent unsupported fields are not deletions.
`series_id` is canonical grouping; UID alone is never cross-source identity.

## Transaction and adapter contract

Lock order: Calendar -> Bindings by ID -> Resources by ID -> Events by ID.
Connection lifecycle never takes a Calendar lock while holding connection locks.
No network I/O inside DB transactions.

`Data.CalendarSyncState.stage_events!(calendar, events, source: context)` updates
each enrolled target independently and queues `Connectors.Jobs.SyncCalendar` via
worker string. New local events enroll on already confirmed active/paused targets;
historical events enroll only by confirmed manifest. Detached targets are excluded.
Source context carries binding ID and accepted projection; other targets receive
canonical revisions atomically. Notify `calendar:changes` after commands/sync.

`Connectors.CalendarSync` owns preview/confirm, pause/resume/detach, conflict
resolution, leased run and durable attempts. Adapters use:

```elixir
discover(connection, opts) # {:ok, [%{id:, name:, capabilities:, metadata:}]} | {:error, reason}
fetch_changes(binding, checkpoint, opts)
# {:ok, %{complete: true, mode: :full | :delta, checkpoint: %{}, resources: [...]} }
# resource: %{id:, href:, raw:, etag:, presence: :present | :deleted, metadata: %{}}
fetch_resource(resource, opts) # {:ok, resource_snapshot} | {:error, reason}
decode(snapshot, opts)
# {:ok, [%{key: string, projection: string_key_map, fields: [string], metadata: %{}}]}
encode(resource, components, opts)
# components: [%{key:, event:, projection:}]; returns {:ok, payload} | {:error, reason}
execute(attempt, connection, opts)
# {:ok, %{etag: ..., raw: ...}} | {:error, :conflict | :unknown | :unauthorized | reason}
```

Adapters get credentials through CalendarConnections; opts permit controlled
transport/endpoints only in tests. Fresh identities reserved before create dispatch.
Never advance checkpoint for incomplete pagination; container loss is not deletion.
Compare covered semantic projections, retain unknown provider content.

## Pure occurrence contract

`Calendars.Time.parse/3`, `period/2`, `compact/1` and
`Recurrence.occurrences/4` implement bounded occurrence expansion with explicit
errors. Occurrences include event/event_id/master_id/recurrence_id/starts_at/
ends_at/date/clock/all_day. Moved exceptions retain original recurrence slots.
Full RDATE/EXDATE lines preserve parameterized timezone/date meanings.

## Progress

- Contract implemented in the scoped worktree. See [validation](calendar-validation.md)
  for current test, migration and browser evidence.
- Independent worktree dependencies and dedicated test databases are used; copied
  stale build metadata and absent initial database were resolved during setup.
- No real provider writes or development DB migrations performed. Legacy Calendar
  dispatch is retired; Contacts continues on its existing path.

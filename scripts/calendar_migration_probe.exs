# Run only against a disposable database whose name contains calendar_migration_.
# mix ecto.create first; mix run --no-start scripts/calendar_migration_probe.exs.
unless String.contains?(System.get_env("TEST_DATABASE_URL", ""), "calendar_migration_") do
  raise "This probe requires its own disposable calendar_migration_ database"
end

{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:crypto)
Logger.configure(level: :warning)
{:ok, _} = Manifold.Repo.start_link()
alias Manifold.Repo
alias Manifold.Connectors.Crypto

alias Manifold.Data.Schema.{
  Calendar,
  CalendarEvent,
  CalendarConnection,
  CalendarBinding,
  CalendarSyncResource,
  CalendarEventBinding,
  CalendarSyncAttempt
}

import Ecto.Query

path = Path.expand("../apps/manifold_data/priv/repo/migrations", __DIR__)
Ecto.Migrator.run(Repo, path, :up, to: 20_261_010_000_200, log: false)
now = DateTime.utc_now() |> DateTime.to_naive()
connection_id = Ecto.UUID.generate()
collection_id = Ecto.UUID.generate()
calendar_id = Ecto.UUID.generate()
context = "icloud:#{connection_id}:app_password"
{:ok, ciphertext} = Crypto.encrypt("probe-only-password", context)

Repo.query!(
  "INSERT INTO icloud_connections (id,apple_id,password_ciphertext,generation,inserted_at,updated_at) VALUES ($1::text::uuid,'probe@example.test',$2,9,$3,$3)",
  [connection_id, ciphertext, now]
)

Repo.query!(
  "INSERT INTO dav_collections (id,connection_id,kind,href,name,sync_token,writable,inserted_at,updated_at) VALUES ($1::text::uuid,$2::text::uuid,'calendars','https://caldav.icloud.com/probe/','Probe','old-checkpoint',true,$3,$3)",
  [collection_id, connection_id, now]
)

Repo.query!(
  "INSERT INTO calendars (id,collection_id,name,inserted_at,updated_at) VALUES ($1::text::uuid,$2::text::uuid,'Retained local ID',$3,$3)",
  [calendar_id, collection_id, now]
)

event_ids =
  for {status, index} <- Enum.with_index(~w(pending conflict uncertain synced)) do
    resource_id = Ecto.UUID.generate()
    event_id = Ecto.UUID.generate()
    sent_revision = if status == "uncertain", do: 5
    sent_raw = if sent_revision, do: "immutable old payload"
    remote_raw = if status == "conflict", do: "unaccepted candidate"

    Repo.query!(
      """
      INSERT INTO dav_resources (id,kind,connection_id,collection_id,href,uid,base_raw,etag,
        desired_revision,acknowledged_revision,status,sent_revision,sent_operation,sent_generation,
        sent_raw,sent_etag,remote_raw,remote_etag,last_error,inserted_at,updated_at)
      VALUES ($1::text::uuid,'calendars',$2::text::uuid,$3::text::uuid,$4,'same-uid',
        'retained original ICS','"base"',7,3,$5,$6,'upsert',9,$7,'"sent"',$8,'"candidate"',
        'retained error',$9,$9)
      """,
      [
        resource_id,
        connection_id,
        collection_id,
        "https://caldav.icloud.com/probe/#{index}.ics",
        status,
        sent_revision,
        sent_raw,
        remote_raw,
        now
      ]
    )

    Repo.query!(
      """
      INSERT INTO calendar_events (id,calendar_id,collection_id,resource_id,resource_href,uid,
        raw,etag,summary,starts_at,local_revision,deleted_at,inserted_at,updated_at)
      VALUES ($1::text::uuid,$2::text::uuid,$3::text::uuid,$4::text::uuid,$5,'same-uid',
        'retained original ICS','"base"',$6,'20261019T100000Z',2,$7,$8,$8)
      """,
      [
        event_id,
        calendar_id,
        collection_id,
        resource_id,
        "https://caldav.icloud.com/probe/#{index}.ics",
        status,
        if(index == 2, do: now),
        now
      ]
    )

    event_id
  end

local_id = Ecto.UUID.generate()

Repo.query!(
  "INSERT INTO calendar_events (id,calendar_id,uid,summary,starts_at,local_revision,inserted_at,updated_at) VALUES ($1::text::uuid,$2::text::uuid,'local-draft','not enrolled','20261020',1,$3,$3)",
  [local_id, calendar_id, now]
)

before =
  Repo.query!(
    "SELECT id,calendar_id,resource_id,uid,raw,summary,starts_at,local_revision,deleted_at FROM calendar_events ORDER BY id"
  ).rows

# The probe starts only SQL dependencies. Also instrument the shared HTTP boundary
# so a future application migration cannot silently introduce provider traffic.
Code.ensure_loaded!(Manifold.Core.HTTPClient)

watcher =
  spawn(fn ->
    loop = fn loop, count ->
      receive do
        {:trace, _, :call, _} -> loop.(loop, count + 1)
        {:count, parent} -> send(parent, {:http_calls, count})
      end
    end

    loop.(loop, 0)
  end)

:erlang.trace_pattern({Manifold.Core.HTTPClient, :request, 1}, true, [])
:erlang.trace(:all, true, [:call, {:tracer, watcher}])
Ecto.Migrator.run(Repo, path, :up, all: true, log: false)
:erlang.trace(:all, false, [:call])
:erlang.trace_pattern({Manifold.Core.HTTPClient, :request, 1}, false, [])
send(watcher, {:count, self()})

receive do
  {:http_calls, 0} -> :ok
  {:http_calls, count} -> raise "Migration unexpectedly issued #{count} HTTP calls"
after
  5_000 -> raise "missing HTTP instrumentation result"
end

assert = fn condition, message -> unless condition, do: raise(message) end

after_rows =
  Repo.query!(
    "SELECT id,calendar_id,resource_id,uid,raw,summary,starts_at,local_revision,deleted_at FROM calendar_events ORDER BY id"
  ).rows

assert.(before == after_rows, "Canonical IDs or data changed during migration")
calendar = Repo.get!(Calendar, calendar_id)
assert.(calendar.name == "Retained local ID", "Calendar identity changed")
connection = Repo.get_by!(CalendarConnection, legacy_connection_id: connection_id)

assert.(
  connection.status == "paused" and is_nil(connection.remote_identity),
  "Unverified identity activated"
)

assert.(
  connection.credential_context == context and connection.encrypted_credentials == ciphertext,
  "Original credential context lost"
)

assert.(
  Crypto.decrypt(connection.encrypted_credentials, connection.credential_context) ==
    {:ok, "probe-only-password"},
  "Credential no longer decrypts"
)

binding = Repo.get_by!(CalendarBinding, legacy_collection_id: collection_id)

assert.(
  binding.calendar_id == calendar.id and binding.state == "paused",
  "Binding changed canonical calendar"
)

assert.(binding.checkpoint["sync_token"] == "old-checkpoint", "Checkpoint lost")
assert.(Repo.aggregate(CalendarSyncResource, :count) == 4, "Resource mapping count differs")
assert.(Repo.aggregate(CalendarEventBinding, :count) == 4, "Unbound history was enrolled")

assert.(
  is_nil(Repo.get_by(CalendarEventBinding, event_id: local_id)),
  "Local draft auto-enrolled"
)

assert.(
  Repo.all(from e in CalendarEvent, where: e.id in ^event_ids, select: e.series_id)
  |> Enum.uniq()
  |> length() == 4,
  "Unrelated UIDs merged"
)

attempt = Repo.one!(CalendarSyncAttempt)

assert.(
  attempt.payload == "immutable old payload" and attempt.state == "uncertain",
  "In-flight evidence changed"
)

assert.(
  attempt.component_revisions == %{} and attempt.sent_projections == %{},
  "Legacy vector invented"
)

assert.(
  attempt.legacy_snapshot["sent_revision"] == 5 and
    attempt.legacy_snapshot["desired_revision"] == 7,
  "Legacy counters lost"
)

assert.(
  Repo.one!(from eb in CalendarEventBinding, select: max(eb.acknowledged_revision)) == 0,
  "Current event revisions wrongly acknowledged"
)

assert.(
  Enum.any?(Repo.all(CalendarEventBinding), &(&1.conflict && &1.conflict["legacy"])),
  "Conflict candidate lost"
)

IO.puts(
  Jason.encode!(%{
    result: "PASS",
    canonical_events_preserved: length(before),
    resources_preserved: 4,
    bindings_paused: 1,
    unknown_attempts_preserved: 1,
    invented_component_vectors: 0,
    auto_enrolled_drafts: 0,
    http_requests: 0,
    original_credential_context_preserved: true
  })
)

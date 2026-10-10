# Run from umbrella root with MIX_ENV=test mix run --no-start <this file>.
# Uses a newly named database and leaves it available for independent inspection.
alias Manifold.Data.Schema.{Calendar, CalendarEvent, Contact, DAVResource, ICloudConnection}
alias Manifold.Repo

if Process.whereis(Repo), do: raise("Run with --no-start; an existing Repo must not be reused")
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
Logger.configure(level: :warning)

database = "manifold_icloud_upgrade_#{System.system_time(:microsecond)}"
config = Application.fetch_env!(:manifold_data, Repo)

config =
  config
  |> Keyword.delete(:url)
  |> Keyword.put(:database, database)
  |> Keyword.put(:pool, DBConnection.ConnectionPool)

previous_config = Application.fetch_env!(:manifold_data, Repo)
Application.put_env(:manifold_data, Repo, config)
:ok = Ecto.Adapters.Postgres.storage_up(config)
{:ok, repo} = Repo.start_link(config)
migrations = Path.expand("../../priv/repo/migrations", __DIR__)

check = fn condition, message -> if not condition, do: raise(message) end

ids =
  Map.new(
    [:connection, :contacts, :calendar, :imported, :local, :master, :exception],
    &{&1, Ecto.UUID.generate()}
  )

param = fn id -> Ecto.UUID.dump!(Map.fetch!(ids, id)) end
card = "BEGIN:VCARD\r\nVERSION:3.0\r\nUID:ada\r\nFN:Ada\r\nEND:VCARD\r\n"

ics =
  "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nBEGIN:VEVENT\r\nUID:series\r\nDTSTART:20261010T100000Z\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:series\r\nRECURRENCE-ID:20261017T100000Z\r\nDTSTART:20261017T110000Z\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n"

try do
  check.(
    Repo.query!("SELECT current_database()").rows == [[database]],
    "Repo did not use the isolated upgrade database"
  )

  baseline_versions = Ecto.Migrator.run(Repo, migrations, :up, to: 20_261_010_000_100, log: false)

  check.(
    20_261_010_000_100 in baseline_versions,
    "Baseline migration did not run on the isolated database"
  )

  Repo.query!(
    "INSERT INTO icloud_connections (id, apple_id, password_ciphertext, inserted_at, updated_at) VALUES ($1, 'fixture@example.test', $2, now(), now())",
    [param.(:connection), <<1, 2, 3>>]
  )

  for {id, kind} <- [{:contacts, "contacts"}, {:calendar, "calendars"}] do
    Repo.query!(
      "INSERT INTO dav_collections (id, connection_id, kind, href, name, inserted_at, updated_at) VALUES ($1, $2, $3, $4, $3, now(), now())",
      [param.(id), param.(:connection), kind, "/#{kind}/"]
    )
  end

  Repo.query!(
    "INSERT INTO contacts (id, collection_id, resource_href, uid, raw, etag, full_name, inserted_at, updated_at) VALUES ($1, $2, '/ada.vcf', 'ada', $3, '\"card-base\"', 'Imported Ada', now(), now())",
    [param.(:imported), param.(:contacts), card]
  )

  Repo.query!(
    "INSERT INTO contacts (id, full_name, inserted_at, updated_at) VALUES ($1, 'Local Ada', now(), now())",
    [param.(:local)]
  )

  for {id, recurrence} <- [{:master, ""}, {:exception, "20261017T100000Z"}] do
    Repo.query!(
      "INSERT INTO calendar_events (id, collection_id, resource_href, uid, recurrence_id, raw, etag, starts_at, inserted_at, updated_at) VALUES ($1, $2, '/series.ics', 'series', $3, $4, '\"event-base\"', '20261010T100000Z', now(), now())",
      [param.(id), param.(:calendar), recurrence, ics]
    )
  end

  upgraded_versions = Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)
  check.(20_261_010_000_200 in upgraded_versions, "Bidirectional upgrade migration did not run")

  check.(
    Repo.query!("SELECT current_database()").rows == [[database]],
    "Upgrade switched away from its isolated database"
  )

  imported = Repo.get!(Contact, ids.imported)
  local = Repo.get!(Contact, ids.local)
  master = Repo.get!(CalendarEvent, ids.master)
  exception = Repo.get!(CalendarEvent, ids.exception)

  check.(
    imported.raw == card and imported.resource_href == "/ada.vcf" and imported.sync_to_icloud,
    "Contact identity/raw/preference changed"
  )

  check.(
    is_nil(local.account_id) and is_nil(local.resource_id),
    "Unassigned local contact was enrolled"
  )

  check.(
    master.raw == ics and exception.raw == ics and master.resource_id == exception.resource_id,
    "Series components lost their complete shared resource"
  )

  check.(
    master.calendar_id == exception.calendar_id and
      Repo.get!(Calendar, master.calendar_id).collection_id == ids.calendar,
    "Local calendar migration changed collection identity"
  )

  resources = Repo.all(DAVResource)

  check.(
    length(resources) == 2 and
      Enum.all?(
        resources,
        &(&1.desired_revision == 0 and &1.acknowledged_revision == 0 and &1.status == "paused")
      ),
    "Migration produced outbound revisions"
  )

  check.(Repo.aggregate(Oban.Job, :count) == 0, "Migration queued uploads")

  check.(
    is_nil(Repo.get!(ICloudConnection, ids.connection).account_id),
    "Migration guessed Account ownership"
  )

  Repo.delete!(Repo.get!(ICloudConnection, ids.connection))

  check.(
    Enum.all?([ids.imported, ids.local], &(not is_nil(Repo.get(Contact, &1)))),
    "Connection delete removed retained Contacts"
  )

  check.(
    Enum.all?([ids.master, ids.exception], &(not is_nil(Repo.get(CalendarEvent, &1)))),
    "Connection delete removed retained events"
  )

  check.(
    Repo.aggregate(Calendar, :count) == 1 and Repo.aggregate(DAVResource, :count) == 2,
    "Connection delete removed local calendars or resource suppression mappings"
  )

  IO.puts(
    "ICLOUD_POPULATED_UPGRADE_PASS database=#{database} contacts=2 events=2 resources=2 queued_uploads=0"
  )
after
  GenServer.stop(repo)
  Application.put_env(:manifold_data, Repo, previous_config)
end

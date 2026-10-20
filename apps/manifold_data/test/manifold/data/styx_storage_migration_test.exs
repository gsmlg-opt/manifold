defmodule Manifold.Data.StyxStorageMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Migrator
  alias Manifold.Repo.Migrations.{AddOban, MigrateObanStorageToStyx}

  @fresh_version 20_260_728_000_000
  @upgrade_version 20_261_021_000_000
  @migrations Path.expand("../../../priv/repo/migrations", __DIR__)

  for file <- ["20260728000000_add_oban.exs", "20261021000000_migrate_oban_storage_to_styx.exs"],
      File.exists?(Path.join(@migrations, file)) do
    module = if file == "20260728000000_add_oban.exs", do: AddOban, else: MigrateObanStorageToStyx
    unless Code.ensure_loaded?(module), do: Code.require_file(Path.join(@migrations, file))
  end

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :manifold_data, adapter: Ecto.Adapters.Postgres
  end

  setup do
    schema = "styx_storage_#{System.unique_integer([:positive])}"
    admin_query!(~s(CREATE SCHEMA "#{schema}"))

    config =
      Manifold.Repo.config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:parameters, search_path: schema)

    repo_pid = start_supervised!({MigrationRepo, config})

    on_exit(fn ->
      if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid)
      admin_query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
    end)

    %{schema: schema}
  end

  test "fresh installs have canonical Styx V1 storage and no Oban tables", ctx do
    migrate(AddOban, @fresh_version, :up, ctx)
    assert table?("styx_jobs")
    refute table?("oban_jobs")

    assert %{rows: [["1"]]} =
             MigrationRepo.query!("SELECT obj_description('styx_jobs'::regclass)")

    migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    migrate(MigrateObanStorageToStyx, @upgrade_version, :down, ctx)
    assert table?("styx_jobs")
    migrate(AddOban, @fresh_version, :down, ctx)
    refute table?("styx_jobs")
  end

  test "upgrade preserves every durable field and old sequence high water", ctx do
    legacy!()
    seed!()
    expected = jobs("oban_jobs", true)
    migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    assert jobs("styx_jobs") == expected
    refute table?("oban_jobs")
    assert %{rows: [[0]]} = MigrationRepo.query!("SELECT count(*) FROM styx_peers")
    assert %{rows: [[10_001]]} = MigrationRepo.query!("SELECT nextval('styx_jobs_id_seq')")

    assert %{rows: [["1"]]} =
             MigrationRepo.query!("SELECT obj_description('styx_jobs'::regclass)")
  end

  test "upgrade advances beyond explicit IDs even when the old sequence is behind", ctx do
    legacy!()

    MigrationRepo.query!(
      "INSERT INTO oban_jobs(id, worker, args) VALUES (40000, 'Manifold.Outbound.Worker', '{}')"
    )

    migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    assert %{rows: [[40_001]]} = MigrationRepo.query!("SELECT nextval('styx_jobs_id_seq')")
  end

  test "an empty old database keeps the first canonical ID available", ctx do
    legacy!()
    migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    assert %{rows: [[1]]} = MigrationRepo.query!("SELECT nextval('styx_jobs_id_seq')")
  end

  test "a copy failure rolls back the canonical schema and leaves source rows intact", ctx do
    legacy!()
    seed!()
    MigrationRepo.query!("ALTER TYPE oban_job_state ADD VALUE 'unsupported'")
    MigrationRepo.query!("UPDATE oban_jobs SET state = 'unsupported' WHERE id = 1")
    expected = jobs("oban_jobs")

    assert_raise Postgrex.Error, fn ->
      migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    end

    assert jobs("oban_jobs") == expected
    refute table?("styx_jobs")
    refute table?("oban_jobs_styx_rollback")
  end

  test "rollback copies current states and new jobs without resurrecting deleted jobs", ctx do
    legacy!()
    seed!()
    migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    MigrationRepo.query!("DELETE FROM styx_jobs WHERE id = 1")

    MigrationRepo.query!(
      "UPDATE styx_jobs SET state = 'completed', completed_at = '2026-10-21' WHERE id = 2"
    )

    MigrationRepo.query!(
      "INSERT INTO styx_jobs(worker, args) VALUES ('Manifold.Outbound.Worker', '{\"new\": true}')"
    )

    MigrationRepo.query!("SELECT setval('styx_jobs_id_seq', 20000)")
    expected = jobs("styx_jobs")
    migrate(MigrateObanStorageToStyx, @upgrade_version, :down, ctx)
    assert jobs("oban_jobs") == expected
    refute table?("styx_jobs")
    assert %{rows: [[20_001]]} = MigrationRepo.query!("SELECT nextval('oban_jobs_id_seq')")
    assert %{rows: [[0]]} = MigrationRepo.query!("SELECT count(*) FROM oban_peers")
    migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    assert jobs("styx_jobs") == expected
  end

  for field <- ["tags", "attempted_by"] do
    test "upgrade rejects oversized #{field} without modifying legacy storage", ctx do
      legacy!()
      seed!()

      MigrationRepo.query!("UPDATE oban_jobs SET #{unquote(field)} = ARRAY[$1] WHERE id = 1", [
        String.duplicate("界", 256)
      ])

      expected = jobs("oban_jobs")

      assert_raise Ecto.MigrationError, ~r/255/, fn ->
        migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
      end

      assert jobs("oban_jobs") == expected
      refute table?("styx_jobs")
    end
  end

  test "upgrade refuses independent Styx history even after pruning", ctx do
    legacy!()
    seed!()
    migrate(AddOban, @fresh_version, :up, ctx)
    MigrationRepo.query!("SELECT setval('styx_jobs_id_seq', 1234)")

    assert_raise Ecto.MigrationError, ~r/independent Styx history/, fn ->
      migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    end

    assert length(jobs("oban_jobs")) == 7
  end

  test "upgrade refuses nonempty independently populated Styx storage", ctx do
    legacy!()
    seed!()
    migrate(AddOban, @fresh_version, :up, ctx)

    MigrationRepo.query!(
      "INSERT INTO styx_jobs(id, worker, args) VALUES (999, 'Other.Worker', '{}')"
    )

    expected_old = jobs("oban_jobs")
    expected_new = jobs("styx_jobs")

    assert_raise Ecto.MigrationError, ~r/independent Styx history/, fn ->
      migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    end

    assert jobs("oban_jobs") == expected_old
    assert jobs("styx_jobs") == expected_new
  end

  test "upgrade rejects executing jobs without altering them", ctx do
    legacy!()
    seed!()
    MigrationRepo.query!("UPDATE oban_jobs SET state = 'executing' WHERE id = 1")
    expected = jobs("oban_jobs")

    assert_raise Ecto.MigrationError, ~r/executing/, fn ->
      migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    end

    assert jobs("oban_jobs") == expected
    refute table?("styx_jobs")
  end

  test "rollback rejects executing jobs without altering them", ctx do
    legacy!()
    seed!()
    migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    MigrationRepo.query!("UPDATE styx_jobs SET state = 'executing' WHERE id = 1")
    expected = jobs("styx_jobs")

    assert_raise Ecto.MigrationError, ~r/executing/, fn ->
      migrate(MigrateObanStorageToStyx, @upgrade_version, :down, ctx)
    end

    assert jobs("styx_jobs") == expected
  end

  test "rollback refuses independently populated old storage", ctx do
    legacy!()
    seed!()
    migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)

    MigrationRepo.query!(
      "INSERT INTO oban_jobs_styx_rollback(worker, args) VALUES ('Other.Worker', '{}')"
    )

    expected = jobs("styx_jobs")

    assert_raise Ecto.MigrationError, ~r/rollback table/, fn ->
      migrate(MigrateObanStorageToStyx, @upgrade_version, :down, ctx)
    end

    assert jobs("styx_jobs") == expected
  end

  test "rollback fails transactionally when the old enum cannot represent a state", ctx do
    legacy!()
    seed!()
    migrate(MigrateObanStorageToStyx, @upgrade_version, :up, ctx)
    MigrationRepo.query!("ALTER TABLE oban_jobs_styx_rollback ALTER COLUMN state DROP DEFAULT")
    MigrationRepo.query!("ALTER TYPE oban_job_state RENAME TO oban_job_state_original")
    MigrationRepo.query!("CREATE TYPE oban_job_state AS ENUM ('available')")

    MigrationRepo.query!(
      "ALTER TABLE oban_jobs_styx_rollback ALTER COLUMN state TYPE oban_job_state USING state::text::oban_job_state"
    )

    expected = jobs("styx_jobs")

    assert_raise Postgrex.Error, fn ->
      migrate(MigrateObanStorageToStyx, @upgrade_version, :down, ctx)
    end

    assert jobs("styx_jobs") == expected
    assert %{rows: [[0]]} = MigrationRepo.query!("SELECT count(*) FROM oban_jobs_styx_rollback")
  end

  defp migrate(module, version, direction, %{schema: schema}) do
    Migrator.run(MigrationRepo, [{version, module}], direction,
      all: true,
      log: false,
      prefix: schema
    )
  end

  defp legacy! do
    "fixtures/oban_v14.sql"
    |> Path.expand(__DIR__)
    |> File.read!()
    |> String.split(";", trim: true)
    |> Enum.each(&MigrationRepo.query!/1)
  end

  defp seed! do
    MigrationRepo.query!("""
    INSERT INTO oban_jobs (
      id, state, queue, worker, args, meta, tags, errors, attempt, attempted_by,
      max_attempts, priority, inserted_at, scheduled_at, attempted_at, completed_at,
      discarded_at, cancelled_at
    ) SELECT n, state::oban_job_state, 'outbound', 'Manifold.Outbound.Worker',
      jsonb_build_object('nested', jsonb_build_array(n, true, 'payload')),
      CASE WHEN n = 1 THEN NULL ELSE '{"snoozed": 2, "custom": "kept"}'::jsonb END,
      CASE WHEN n = 1 THEN NULL ELSE ARRAY['tag', repeat('界', 255)] END,
      ARRAY['{"attempt": 1, "at": "2026-10-20T12:00:00Z", "error": "failure"}'::jsonb],
      2, CASE WHEN n = 1 THEN NULL ELSE ARRAY['node@host', 'worker-id'] END, 9, 6,
      '2026-10-19 10:11:12.123456'::timestamp,
      '2026-10-22 10:11:12.123456'::timestamp,
      '2026-10-20 10:11:12.123456'::timestamp,
      '2026-10-20 11:11:12.123456'::timestamp,
      '2026-10-20 12:11:12.123456'::timestamp,
      '2026-10-20 13:11:12.123456'::timestamp
    FROM unnest(ARRAY['available', 'suspended', 'scheduled', 'retryable',
                     'completed', 'discarded', 'cancelled']) WITH ORDINALITY AS s(state, n)
    """)

    MigrationRepo.query!("SELECT setval('oban_jobs_id_seq', 10000)")
    MigrationRepo.query!("INSERT INTO oban_peers VALUES ('old', 'old@node', now(), now())")
  end

  defp jobs(table, normalize \\ false) do
    tags = if normalize, do: "coalesce(tags, '{}')", else: "tags"
    meta = if normalize, do: "coalesce(meta, '{}')", else: "meta"

    MigrationRepo.query!("""
    SELECT id, state::text, queue, worker, args, #{meta}, #{tags}::text[], errors,
           attempt, attempted_by::text[], max_attempts, priority, inserted_at,
           scheduled_at, attempted_at, completed_at, discarded_at, cancelled_at
    FROM #{table} ORDER BY id
    """).rows
  end

  defp table?(table) do
    %{rows: [[exists]]} = MigrationRepo.query!("SELECT to_regclass($1) IS NOT NULL", [table])
    exists
  end

  defp admin_query!(sql) do
    config =
      Keyword.take(Manifold.Repo.config(), [
        :hostname,
        :port,
        :username,
        :password,
        :database,
        :socket_dir
      ])

    {:ok, connection} = Postgrex.start_link(config)

    try do
      Postgrex.query!(connection, sql, [])
    after
      GenServer.stop(connection)
    end
  end
end

defmodule Manifold.Repo.Migrations.MigrateObanStorageToStyx do
  use Ecto.Migration

  @columns ~w(id state queue worker args meta tags errors attempt attempted_by max_attempts
              priority inserted_at scheduled_at attempted_at completed_at discarded_at cancelled_at)

  # Stop all job producers and consumers before either direction. Table locks protect
  # the copy, but cannot certify that an external submission has stopped executing.
  def up do
    if exists?("oban_jobs_styx_rollback") do
      raise Ecto.MigrationError,
            "Unexpected Oban rollback table; inspect storage before migrating"
    end

    if exists?("oban_jobs") do
      lock!("oban_jobs")
      reject_executing!("oban_jobs")
      validate_arrays!()
      reject_styx_history!()

      Styx.Migration.up(prefix: schema(), create_schema: false)
      flush()
      lock!("styx_jobs")
      copy!("oban_jobs", "styx_jobs", :up)
      advance_sequence!("oban_jobs", "styx_jobs")

      # Retain an empty schema for rollback, not a snapshot that could replay jobs.
      query!("TRUNCATE TABLE #{qualified("oban_jobs")}")
      query!("ALTER TABLE #{qualified("oban_jobs")} RENAME TO oban_jobs_styx_rollback")

      if exists?("oban_peers") do
        query!("TRUNCATE TABLE #{qualified("oban_peers")}")
        query!("ALTER TABLE #{qualified("oban_peers")} RENAME TO oban_peers_styx_rollback")
      end
    end
  end

  def down do
    if exists?("oban_jobs_styx_rollback") do
      if exists?("oban_jobs") or exists?("oban_peers") do
        raise Ecto.MigrationError, "Independent Oban storage exists; refusing rollback"
      end

      lock!("styx_jobs")
      lock!("oban_jobs_styx_rollback")
      reject_executing!("styx_jobs")

      if populated?("oban_jobs_styx_rollback") do
        raise Ecto.MigrationError,
              "Oban rollback table is not empty; refusing to merge independent jobs"
      end

      copy!("styx_jobs", "oban_jobs_styx_rollback", :down)
      advance_sequence!("styx_jobs", "oban_jobs_styx_rollback")
      Styx.Migration.down(prefix: schema())
      flush()

      query!("ALTER TABLE #{qualified("oban_jobs_styx_rollback")} RENAME TO oban_jobs")

      if exists?("oban_peers_styx_rollback") do
        query!("TRUNCATE TABLE #{qualified("oban_peers_styx_rollback")}")
        query!("ALTER TABLE #{qualified("oban_peers_styx_rollback")} RENAME TO oban_peers")
      end
    end
  end

  defp validate_arrays! do
    for column <- ~w(tags attempted_by) do
      %{rows: [[oversized?]]} =
        query!("""
        SELECT EXISTS (
          SELECT 1 FROM #{qualified("oban_jobs")}, unnest(#{column}) AS item
          WHERE char_length(item) > 255
        )
        """)

      if oversized? do
        raise Ecto.MigrationError,
              "Oban #{column} contains values longer than Styx's 255-character limit; refusing truncation"
      end
    end
  end

  defp reject_styx_history! do
    if exists?("styx_jobs") do
      lock!("styx_jobs")
      {_sequence, high_water} = sequence("styx_jobs")

      if populated?("styx_jobs") or high_water > 0 do
        raise Ecto.MigrationError, "Cannot merge independent Styx history with Oban jobs"
      end
    end
  end

  defp reject_executing!(name) do
    %{rows: [[executing?]]} =
      query!("SELECT EXISTS (SELECT 1 FROM #{qualified(name)} WHERE state::text = 'executing')")

    if executing? do
      raise Ecto.MigrationError,
            "Cannot migrate executing jobs in #{name}; stop consumers and reconcile in-flight submissions first"
    end
  end

  defp copy!(source, target, direction) do
    state_type = if direction == :up, do: "styx_job_state", else: "oban_job_state"

    expressions =
      Enum.map_join(@columns, ", ", fn
        "state" -> "state::text::#{qualified(state_type)}"
        "tags" when direction == :up -> "coalesce(tags, '{}')::varchar(255)[]"
        "attempted_by" when direction == :up -> "attempted_by::varchar(255)[]"
        "meta" when direction == :up -> "coalesce(meta, '{}'::jsonb)"
        column -> column
      end)

    query!("""
    INSERT INTO #{qualified(target)} (#{Enum.join(@columns, ", ")})
    SELECT #{expressions} FROM #{qualified(source)}
    """)
  end

  defp advance_sequence!(source, target) do
    {_source_sequence, source_high} = sequence(source)
    {target_sequence, target_high} = sequence(target)
    %{rows: [[maximum]]} = query!("SELECT coalesce(max(id), 0) FROM #{qualified(target)}")
    high = Enum.max([source_high, target_high, maximum])

    # PostgreSQL sequence changes aren't transactional. Only advance, after the
    # copy succeeds, so a later failure can leave a gap but never reuse an ID.
    repo().query!(
      "SELECT setval($1::text::regclass, $2, $3)",
      [target_sequence, max(high, 1), high > 0],
      log: false
    )
  end

  defp sequence(name) do
    %{rows: [[sequence]]} =
      repo().query!("SELECT pg_get_serial_sequence($1, 'id')", [qualified(name)], log: false)

    %{rows: [[last, called?]]} = query!("SELECT last_value, is_called FROM #{sequence}")
    {sequence, if(called?, do: last, else: last - 1)}
  end

  defp populated?(name) do
    %{rows: [[populated?]]} = query!("SELECT EXISTS (SELECT 1 FROM #{qualified(name)})")
    populated?
  end

  defp exists?(name) do
    %{rows: [[exists?]]} =
      repo().query!("SELECT to_regclass($1) IS NOT NULL", [qualified(name)], log: false)

    exists?
  end

  defp lock!(name), do: query!("LOCK TABLE #{qualified(name)} IN ACCESS EXCLUSIVE MODE")
  defp query!(sql), do: repo().query!(sql, [], log: false)
  defp schema, do: prefix() || "public"
  defp qualified(name), do: quote_identifier(schema()) <> "." <> quote_identifier(name)
  defp quote_identifier(name), do: ~s("#{String.replace(name, "\"", "\"\"")}")
end

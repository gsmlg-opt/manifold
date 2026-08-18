defmodule Manifold.Repo.Migrations.AddOAuthProviderSettingsTest do
  use ExUnit.Case, async: false

  alias Ecto.Migrator
  alias Manifold.Repo.Migrations.AddOAuthProviderSettings

  @migration_version 202_608_180_001_00
  @migration_path Application.app_dir(
                    :manifold_data,
                    "priv/repo/migrations/20260818000100_add_oauth_provider_settings.exs"
                  )

  unless Code.ensure_loaded?(AddOAuthProviderSettings) do
    Code.require_file(@migration_path)
  end

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :manifold_data,
      adapter: Ecto.Adapters.Postgres
  end

  setup do
    schema = "oauth_provider_settings_migration_#{System.unique_integer([:positive])}"
    admin_query!(~s(CREATE SCHEMA "#{schema}"))

    repo_pid = start_supervised!({MigrationRepo, migration_repo_config(schema)})

    MigrationRepo.query!("""
    CREATE TABLE connector_oauth_transactions (
      id uuid PRIMARY KEY
    )
    """)

    on_exit(fn ->
      if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid)
      admin_query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
    end)

    :ok
  end

  test "up creates required ciphertext and positive version constraints with defaults" do
    assert [@migration_version] = migrate_up()
    assert_up_state()

    %{rows: [[1, 1]]} =
      MigrationRepo.query!("""
      INSERT INTO connector_oauth_provider_settings (
        id,
        provider,
        client_id,
        client_secret_ciphertext,
        inserted_at,
        updated_at
      )
      VALUES (
        '10000000-0000-0000-0000-000000000001',
        'gmail',
        'client-id',
        decode('010203', 'hex'),
        NOW(),
        NOW()
      )
      RETURNING key_version, lock_version
      """)

    assert_postgres_error(:not_null_violation, fn ->
      MigrationRepo.query!("""
      INSERT INTO connector_oauth_provider_settings (
        id, provider, client_id, client_secret_ciphertext, inserted_at, updated_at
      )
      VALUES (
        '10000000-0000-0000-0000-000000000002',
        'gmail-null-secret',
        'client-id',
        NULL,
        NOW(),
        NOW()
      )
      """)
    end)

    assert_postgres_error(:check_violation, fn ->
      insert_setting_with_versions(
        "10000000-0000-0000-0000-000000000003",
        "gmail-zero-key",
        0,
        1
      )
    end)

    assert_postgres_error(:check_violation, fn ->
      insert_setting_with_versions(
        "10000000-0000-0000-0000-000000000004",
        "gmail-zero-lock",
        1,
        0
      )
    end)
  end

  test "empty down removes the migration and up reapplies it" do
    assert [@migration_version] = migrate_up()
    assert_up_state()

    assert [@migration_version] = migrate_down()
    refute migration_applied?()
    refute table_exists?("connector_oauth_provider_settings")
    refute column_exists?("connector_oauth_transactions", "oauth_provider_setting_id")

    refute column_exists?(
             "connector_oauth_transactions",
             "oauth_provider_setting_lock_version"
           )

    assert [@migration_version] = migrate_up()
    assert_up_state()
  end

  test "transaction generation constraints reject half-pairs and nonpositive versions" do
    assert [@migration_version] = migrate_up()

    assert_postgres_error(:check_violation, fn ->
      insert_transaction_generation(
        "40000000-0000-0000-0000-000000000001",
        "40000000-0000-0000-0000-000000000002",
        nil
      )
    end)

    assert_postgres_error(:check_violation, fn ->
      insert_transaction_generation(
        "40000000-0000-0000-0000-000000000003",
        nil,
        1
      )
    end)

    assert_postgres_error(:check_violation, fn ->
      insert_transaction_generation(
        "40000000-0000-0000-0000-000000000004",
        "40000000-0000-0000-0000-000000000005",
        0
      )
    end)
  end

  test "down refuses before DDL when a provider setting exists" do
    assert [@migration_version] = migrate_up()

    MigrationRepo.query!("""
    INSERT INTO connector_oauth_provider_settings (
      id,
      provider,
      client_id,
      client_secret_ciphertext,
      inserted_at,
      updated_at
    )
    VALUES (
      '20000000-0000-0000-0000-000000000001',
      'gmail',
      'preserved-client',
      decode('aabbcc', 'hex'),
      NOW(),
      NOW()
    )
    """)

    assert_rollback_refused()
    assert_up_state()

    assert %{rows: [["gmail", "preserved-client", <<0xAA, 0xBB, 0xCC>>]]} =
             MigrationRepo.query!("""
             SELECT provider, client_id, client_secret_ciphertext
             FROM connector_oauth_provider_settings
             WHERE id = '20000000-0000-0000-0000-000000000001'
             """)
  end

  test "down refuses before DDL when a fenced OAuth transaction exists" do
    assert [@migration_version] = migrate_up()

    MigrationRepo.query!("""
    INSERT INTO connector_oauth_transactions (
      id,
      oauth_provider_setting_id,
      oauth_provider_setting_lock_version
    )
    VALUES (
      '30000000-0000-0000-0000-000000000001',
      '30000000-0000-0000-0000-000000000002',
      7
    )
    """)

    assert_rollback_refused()
    assert_up_state()

    assert %{rows: [["30000000-0000-0000-0000-000000000002", 7]]} =
             MigrationRepo.query!("""
             SELECT oauth_provider_setting_id::text, oauth_provider_setting_lock_version
             FROM connector_oauth_transactions
             WHERE id = '30000000-0000-0000-0000-000000000001'
             """)
  end

  defp migrate_up do
    Migrator.run(
      MigrationRepo,
      [{@migration_version, AddOAuthProviderSettings}],
      :up,
      all: true,
      log: false
    )
  end

  defp migrate_down do
    Migrator.run(
      MigrationRepo,
      [{@migration_version, AddOAuthProviderSettings}],
      :down,
      all: true,
      log: false
    )
  end

  defp assert_rollback_refused do
    assert_raise RuntimeError,
                 "cannot roll back OAuth provider settings while settings or fenced transactions exist",
                 &migrate_down/0
  end

  defp assert_up_state do
    assert migration_applied?()
    assert table_exists?("connector_oauth_provider_settings")
    assert column_exists?("connector_oauth_transactions", "oauth_provider_setting_id")

    assert column_exists?(
             "connector_oauth_transactions",
             "oauth_provider_setting_lock_version"
           )
  end

  defp migration_applied? do
    %{rows: rows} =
      MigrationRepo.query!(
        "SELECT version FROM schema_migrations WHERE version = $1",
        [@migration_version]
      )

    rows == [[@migration_version]]
  end

  defp table_exists?(table) do
    %{rows: [[exists?]]} =
      MigrationRepo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM information_schema.tables
          WHERE table_schema = current_schema()
            AND table_name = $1
        )
        """,
        [table]
      )

    exists?
  end

  defp column_exists?(table, column) do
    %{rows: [[exists?]]} =
      MigrationRepo.query!(
        """
        SELECT EXISTS (
          SELECT 1
          FROM information_schema.columns
          WHERE table_schema = current_schema()
            AND table_name = $1
            AND column_name = $2
        )
        """,
        [table, column]
      )

    exists?
  end

  defp insert_setting_with_versions(id, provider, key_version, lock_version) do
    MigrationRepo.query!(
      """
      INSERT INTO connector_oauth_provider_settings (
        id,
        provider,
        client_id,
        client_secret_ciphertext,
        key_version,
        lock_version,
        inserted_at,
        updated_at
      )
      VALUES ($1::uuid, $2, 'client-id', decode('01', 'hex'), $3, $4, NOW(), NOW())
      """,
      [Ecto.UUID.dump!(id), provider, key_version, lock_version]
    )
  end

  defp insert_transaction_generation(id, setting_id, lock_version) do
    MigrationRepo.query!(
      """
      INSERT INTO connector_oauth_transactions (
        id,
        oauth_provider_setting_id,
        oauth_provider_setting_lock_version
      )
      VALUES ($1::uuid, $2::uuid, $3)
      """,
      [Ecto.UUID.dump!(id), dump_uuid(setting_id), lock_version]
    )
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)

  defp assert_postgres_error(code, fun) do
    error = assert_raise Postgrex.Error, fun
    assert %{postgres: %{code: ^code}} = error
  end

  defp migration_repo_config(schema) do
    Manifold.Repo.config()
    |> Keyword.delete(:pool)
    |> Keyword.put(:pool_size, 2)
    |> Keyword.put(:parameters, search_path: schema)
  end

  defp admin_query!(sql) do
    {:ok, connection} = Postgrex.start_link(admin_config())

    try do
      Postgrex.query!(connection, sql, [])
    after
      GenServer.stop(connection)
    end
  end

  defp admin_config do
    Manifold.Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])
  end
end

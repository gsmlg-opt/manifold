defmodule Manifold.Repo.Migrations.AddOAuthDeviceFlowTest do
  use ExUnit.Case, async: false

  alias Ecto.Migrator
  alias Manifold.Repo.Migrations.{AddOAuthProviderAuthFlow, CreateOAuthDeviceTransactions}

  @flow_version 202_610_060_001_00
  @device_version 202_610_060_002_00
  @legacy_id "10000000-0000-0000-0000-000000000001"
  @device_id "10000000-0000-0000-0000-000000000002"

  for {module, file} <- [
        {AddOAuthProviderAuthFlow, "20261006000100_add_oauth_provider_auth_flow.exs"},
        {CreateOAuthDeviceTransactions, "20261006000200_create_oauth_device_transactions.exs"}
      ] do
    unless Code.ensure_loaded?(module) do
      Code.require_file(Application.app_dir(:manifold_data, "priv/repo/migrations/#{file}"))
    end
  end

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :manifold_data, adapter: Ecto.Adapters.Postgres
  end

  setup do
    schema = "oauth_device_migration_#{System.unique_integer([:positive])}"
    admin_query!(~s(CREATE SCHEMA "#{schema}"))

    config =
      Manifold.Repo.config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:parameters, search_path: schema)

    repo_pid = start_supervised!({MigrationRepo, config})
    MigrationRepo.query!("CREATE TABLE mailboxes (id uuid PRIMARY KEY)")

    MigrationRepo.query!("""
    CREATE TABLE connector_oauth_provider_settings (
      id uuid PRIMARY KEY,
      provider text NOT NULL UNIQUE,
      client_id text NOT NULL,
      client_secret_ciphertext bytea NOT NULL,
      key_version integer NOT NULL DEFAULT 1,
      lock_version integer NOT NULL DEFAULT 1,
      inserted_at timestamp NOT NULL,
      updated_at timestamp NOT NULL
    )
    """)

    on_exit(fn ->
      if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid)
      admin_query!(~s(DROP SCHEMA IF EXISTS "#{schema}" CASCADE))
    end)

    :ok
  end

  test "legacy authorization-code settings preserve identity, ciphertext and versions" do
    insert_setting(@legacy_id, "microsoft", nil, <<1, 2, 3>>, legacy?: true)
    assert [@flow_version, @device_version] = migrate(:up)

    assert %{rows: [[@legacy_id, "authorization_code", <<1, 2, 3>>, 2, 7]]} =
             MigrationRepo.query!("""
             SELECT id::text, auth_flow, client_secret_ciphertext, key_version, lock_version
             FROM connector_oauth_provider_settings
             """)

    assert [@device_version, @flow_version] = migrate(:down)

    assert %{rows: [[@legacy_id, <<1, 2, 3>>, 2, 7]]} =
             MigrationRepo.query!("""
             SELECT id::text, client_secret_ciphertext, key_version, lock_version
             FROM connector_oauth_provider_settings
             """)

    assert [@flow_version, @device_version] = migrate(:up)

    assert %{rows: [["authorization_code"]]} =
             MigrationRepo.query!("SELECT auth_flow FROM connector_oauth_provider_settings")
  end

  test "database accepts a secretless Microsoft device client and rejects illegal combinations" do
    migrate(:up)
    insert_setting(@device_id, "microsoft", "device_code", nil)

    for {provider, flow, secret} <- [
          {"gmail", "device_code", nil},
          {"gmail", "authorization_code", nil},
          {"microsoft", "device_code", <<1>>},
          {"microsoft", "unknown", <<1>>}
        ] do
      error =
        assert_raise Postgrex.Error, fn ->
          MigrationRepo.query!(
            "UPDATE connector_oauth_provider_settings SET provider = $1, auth_flow = $2, client_secret_ciphertext = $3 WHERE id = $4::uuid",
            [provider, flow, secret, Ecto.UUID.dump!(@device_id)]
          )
        end

      assert error.postgres.code == :check_violation
    end

    assert %{rows: [["microsoft", "device_code", nil]]} =
             MigrationRepo.query!("""
             SELECT provider, auth_flow, client_secret_ciphertext
             FROM connector_oauth_provider_settings
             """)
  end

  test "new settings without an auth-flow value retain the authorization-code default" do
    migrate(:up)
    insert_setting(@legacy_id, "gmail", nil, <<1, 2, 3>>, legacy?: true)

    assert %{rows: [["authorization_code"]]} =
             MigrationRepo.query!("SELECT auth_flow FROM connector_oauth_provider_settings")
  end

  test "auth-flow rollback refuses device settings before DDL and succeeds after removal" do
    migrate(:up)
    insert_setting(@device_id, "microsoft", "device_code", nil)

    assert_raise Ecto.MigrationError,
                 "Cannot roll back OAuth auth flow while device-code settings exist",
                 fn ->
                   Migrator.run(MigrationRepo, [{@flow_version, AddOAuthProviderAuthFlow}], :down,
                     all: true,
                     log: false
                   )
                 end

    assert %{rows: [["device_code", nil]]} =
             MigrationRepo.query!("""
             SELECT auth_flow, client_secret_ciphertext
             FROM connector_oauth_provider_settings
             """)

    MigrationRepo.query!("DELETE FROM connector_oauth_provider_settings")
    assert [@device_version, @flow_version] = migrate(:down)
    assert [@flow_version, @device_version] = migrate(:up)
  end

  test "empty device migrations support clean up, down and up" do
    assert [@flow_version, @device_version] = migrate(:up)
    assert [@device_version, @flow_version] = migrate(:down)

    assert %{rows: [[nil]]} =
             MigrationRepo.query!(
               "SELECT to_regclass('connector_oauth_device_transactions')::text"
             )

    assert [@flow_version, @device_version] = migrate(:up)

    assert %{rows: [["connector_oauth_device_transactions"]]} =
             MigrationRepo.query!(
               "SELECT to_regclass('connector_oauth_device_transactions')::text"
             )
  end

  test "combined rollback preserves device transactions when device settings still exist" do
    migrate(:up)
    insert_setting(@device_id, "microsoft", "device_code", nil)

    MigrationRepo.query!("INSERT INTO mailboxes (id) VALUES ($1::uuid)", [
      Ecto.UUID.dump!(@legacy_id)
    ])

    MigrationRepo.query!(
      """
      INSERT INTO connector_oauth_device_transactions (
        id, account_id, purpose, required_scopes, oauth_provider_setting_id,
        oauth_provider_setting_lock_version, device_code_ciphertext, user_code,
        verification_uri, expires_at, interval, next_poll_at, inserted_at, updated_at
      ) VALUES (
        $1::uuid, $2::uuid, 'receive', ARRAY['Mail.Read'], $1::uuid, 7,
        decode('aabbcc', 'hex'), 'DISPLAY-CODE', 'https://microsoft.com/devicelogin',
        NOW() + interval '10 minutes', 5, NOW(), NOW(), NOW()
      )
      """,
      [Ecto.UUID.dump!(@device_id), Ecto.UUID.dump!(@legacy_id)]
    )

    assert_raise Ecto.MigrationError,
                 "Cannot remove OAuth device transactions while device-code settings exist; " <>
                   "switch Microsoft OAuth settings to authorization code or remove them before rollback",
                 fn -> migrate(:down) end

    assert %{rows: [[@device_id, <<0xAA, 0xBB, 0xCC>>, "pending"]]} =
             MigrationRepo.query!("""
             SELECT id::text, device_code_ciphertext, status
             FROM connector_oauth_device_transactions
             """)

    assert %{rows: [[[@flow_version, @device_version]]]} =
             MigrationRepo.query!(
               "SELECT array_agg(version ORDER BY version) FROM schema_migrations"
             )

    MigrationRepo.query!("DELETE FROM connector_oauth_provider_settings")
    assert [@device_version, @flow_version] = migrate(:down)
    assert [@flow_version, @device_version] = migrate(:up)
  end

  defp migrate(direction) do
    Migrator.run(
      MigrationRepo,
      [
        {@flow_version, AddOAuthProviderAuthFlow},
        {@device_version, CreateOAuthDeviceTransactions}
      ],
      direction,
      all: true,
      log: false
    )
  end

  defp insert_setting(id, provider, flow, secret, opts \\ []) do
    columns = if opts[:legacy?], do: "", else: ", auth_flow"
    values = if opts[:legacy?], do: "", else: ", $4"
    params = [Ecto.UUID.dump!(id), provider, secret]
    params = if opts[:legacy?], do: params, else: params ++ [flow]

    MigrationRepo.query!(
      """
      INSERT INTO connector_oauth_provider_settings (
        id, provider, client_id, client_secret_ciphertext, key_version, lock_version,
        inserted_at, updated_at#{columns}
      ) VALUES ($1::uuid, $2, 'existing-client', $3, 2, 7, NOW(), NOW()#{values})
      """,
      params
    )
  end

  defp admin_query!(sql) do
    config =
      Manifold.Repo.config()
      |> Keyword.take([:hostname, :port, :username, :password, :database, :socket_dir])

    {:ok, connection} = Postgrex.start_link(config)

    try do
      Postgrex.query!(connection, sql, [])
    after
      GenServer.stop(connection)
    end
  end
end

defmodule Manifold.Repo.Migrations.AddOAuthProviderCallbackUrlTest do
  use ExUnit.Case, async: false

  alias Ecto.Migrator
  alias Manifold.Repo.Migrations.AddOAuthProviderCallbackUrl

  @version 202_610_060_003_00
  @id "10000000-0000-0000-0000-000000000001"

  unless Code.ensure_loaded?(AddOAuthProviderCallbackUrl) do
    Code.require_file(
      Application.app_dir(
        :manifold_data,
        "priv/repo/migrations/20261006000300_add_oauth_provider_callback_url.exs"
      )
    )
  end

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :manifold_data, adapter: Ecto.Adapters.Postgres
  end

  setup do
    schema = "oauth_callback_migration_#{System.unique_integer([:positive])}"
    admin_query!(~s(CREATE SCHEMA "#{schema}"))

    config =
      Manifold.Repo.config()
      |> Keyword.delete(:pool)
      |> Keyword.put(:pool_size, 2)
      |> Keyword.put(:parameters, search_path: schema)

    repo_pid = start_supervised!({MigrationRepo, config})

    MigrationRepo.query!("""
    CREATE TABLE connector_oauth_provider_settings (
      id uuid PRIMARY KEY,
      provider text NOT NULL UNIQUE,
      client_id text NOT NULL,
      auth_flow text NOT NULL DEFAULT 'authorization_code',
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

  test "migration preserves legacy settings and supports up down up" do
    insert_legacy!()
    assert [@version] = migrate(:up)

    assert %{rows: [[@id, "gmail", "authorization_code", nil, <<1, 2>>, 3, 7]]} =
             MigrationRepo.query!("""
             SELECT id::text, provider, auth_flow, callback_url, client_secret_ciphertext,
                    key_version, lock_version FROM connector_oauth_provider_settings
             """)

    assert [@version] = migrate(:down)
    assert [@version] = migrate(:up)

    assert %{rows: [[nil]]} =
             MigrationRepo.query!("SELECT callback_url FROM connector_oauth_provider_settings")
  end

  test "database restricts nonblank callback URLs to Gmail and rollback guards configured URLs" do
    insert_legacy!()
    migrate(:up)

    MigrationRepo.query!("UPDATE connector_oauth_provider_settings SET callback_url = $1", [
      "http://localhost:4290/custom-callback"
    ])

    for sql <- [
          "UPDATE connector_oauth_provider_settings SET provider = 'microsoft'",
          "UPDATE connector_oauth_provider_settings SET callback_url = '   '"
        ] do
      error = assert_raise Postgrex.Error, fn -> MigrationRepo.query!(sql) end
      assert error.postgres.code == :check_violation
    end

    assert_raise Ecto.MigrationError,
                 "Cannot remove OAuth callback URL while configured callback URLs exist; clear them before rollback",
                 fn -> migrate(:down) end

    assert %{rows: [["http://localhost:4290/custom-callback"]]} =
             MigrationRepo.query!("SELECT callback_url FROM connector_oauth_provider_settings")

    MigrationRepo.query!("UPDATE connector_oauth_provider_settings SET callback_url = NULL")
    assert [@version] = migrate(:down)
  end

  defp migrate(direction) do
    Migrator.run(MigrationRepo, [{@version, AddOAuthProviderCallbackUrl}], direction,
      all: true,
      log: false
    )
  end

  defp insert_legacy! do
    MigrationRepo.query!(
      """
      INSERT INTO connector_oauth_provider_settings (
        id, provider, client_id, client_secret_ciphertext, key_version, lock_version,
        inserted_at, updated_at
      ) VALUES ($1::uuid, 'gmail', 'legacy-client', $2, 3, 7, NOW(), NOW())
      """,
      [Ecto.UUID.dump!(@id), <<1, 2>>]
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

defmodule Manifold.Edge.Release do
  @moduledoc """
  Runtime migration entrypoint for the standalone edge release.
  """

  @app :manifold_edge

  @spec migrate() :: [integer()]
  def migrate do
    migrations_path = Application.app_dir(@app, "priv/repo/migrations")

    {:ok, migrated, _apps} =
      Ecto.Migrator.with_repo(Manifold.Edge.Repo, fn repo ->
        Ecto.Migrator.run(repo, migrations_path, :up, all: true)
      end)

    migrated
  end
end

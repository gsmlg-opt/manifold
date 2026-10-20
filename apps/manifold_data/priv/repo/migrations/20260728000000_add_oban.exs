defmodule Manifold.Repo.Migrations.AddOban do
  use Ecto.Migration

  # Keep the historical migration identity for databases that already ran it.
  def up, do: Styx.Migration.up(prefix: prefix() || "public")

  def down, do: Styx.Migration.down(prefix: prefix() || "public")
end

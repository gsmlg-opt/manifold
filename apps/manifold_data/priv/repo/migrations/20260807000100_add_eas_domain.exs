defmodule Manifold.Repo.Migrations.AddEasDomain do
  use Ecto.Migration

  def change do
    alter table(:connector_eas_settings) do
      add(:domain, :text)
    end
  end
end

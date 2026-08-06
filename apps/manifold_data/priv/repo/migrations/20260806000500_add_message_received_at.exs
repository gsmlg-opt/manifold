defmodule Manifold.Repo.Migrations.AddMessageReceivedAt do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add(:received_at, :utc_datetime_usec)
    end
  end
end

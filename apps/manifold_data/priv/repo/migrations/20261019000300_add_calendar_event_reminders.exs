defmodule Manifold.Repo.Migrations.AddCalendarEventReminders do
  use Ecto.Migration

  def change do
    alter table(:calendar_events) do
      add(:reminders, {:array, :map}, null: false, default: [])
    end
  end
end

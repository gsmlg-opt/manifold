defmodule Manifold.Repo.Migrations.AccountReceiveMethods do
  use Ecto.Migration

  def up do
    alter table(:connector_accounts) do
      add(:enabled, :boolean, null: false, default: false)
    end

    execute("""
    WITH ranked AS (
      SELECT
        id,
        ROW_NUMBER() OVER (
          PARTITION BY mailbox_id
          ORDER BY
            CASE WHEN status = 'disconnected' THEN 1 ELSE 0 END,
            inserted_at ASC,
            id ASC
        ) AS rn
      FROM connector_accounts
    )
    UPDATE connector_accounts AS ca
    SET enabled = (ranked.rn = 1 AND ca.status <> 'disconnected')
    FROM ranked
    WHERE ca.id = ranked.id
    """)

    create(
      index(:connector_accounts, [:mailbox_id],
        unique: true,
        where: "enabled = true",
        name: :connector_accounts_one_enabled_per_mailbox_index
      )
    )
  end

  def down do
    drop_if_exists(
      index(:connector_accounts, [:mailbox_id],
        name: :connector_accounts_one_enabled_per_mailbox_index
      )
    )

    alter table(:connector_accounts) do
      remove(:enabled)
    end
  end
end

defmodule Manifold.Repo.Migrations.AddOAuthAuthorizationEvents do
  use Ecto.Migration

  def up do
    alter table(:connector_events) do
      add(
        :oauth_authorization_id,
        references(:connector_oauth_authorizations, type: :binary_id, on_delete: :delete_all)
      )
    end

    execute("ALTER TABLE connector_events ALTER COLUMN external_account_id DROP NOT NULL")

    create(
      constraint(:connector_events, :connector_events_anchor_valid,
        check:
          "(external_account_id IS NOT NULL AND oauth_authorization_id IS NULL) OR " <>
            "(external_account_id IS NULL AND oauth_authorization_id IS NOT NULL)"
      )
    )

    create(index(:connector_events, [:oauth_authorization_id, :occurred_at]))
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM connector_events AS event
        WHERE event.oauth_authorization_id IS NOT NULL
          AND (
            SELECT count(*)
            FROM connector_accounts AS connector_account
            WHERE connector_account.oauth_authorization_id = event.oauth_authorization_id
          ) <> 1
      ) THEN
        RAISE EXCEPTION
          'cannot rollback authorization activity without exactly one legacy receive account';
      END IF;
    END
    $$
    """)

    execute("""
    UPDATE connector_events AS event
    SET external_account_id = connector_account.id,
        oauth_authorization_id = NULL
    FROM connector_accounts AS connector_account
    WHERE event.oauth_authorization_id = connector_account.oauth_authorization_id
    """)

    drop(constraint(:connector_events, :connector_events_anchor_valid))
    drop(index(:connector_events, [:oauth_authorization_id, :occurred_at]))

    alter table(:connector_events) do
      remove(:oauth_authorization_id)
    end

    execute("ALTER TABLE connector_events ALTER COLUMN external_account_id SET NOT NULL")
  end
end

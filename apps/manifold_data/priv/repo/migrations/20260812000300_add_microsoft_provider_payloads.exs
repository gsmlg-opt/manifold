defmodule Manifold.Repo.Migrations.AddMicrosoftProviderPayloads do
  use Ecto.Migration

  @disable_ddl_transaction true
  @backfill_batch_size 500

  def up do
    execute(
      "ALTER TABLE provider_submissions ADD COLUMN IF NOT EXISTS canonical_sender_address text"
    )

    execute("ALTER TABLE provider_submissions ADD COLUMN IF NOT EXISTS render_version integer")
    execute("ALTER TABLE provider_submissions ADD COLUMN IF NOT EXISTS request_payload bytea")
    flush()

    backfill_canonical_senders!()

    add_validated_check(
      "provider_submissions_canonical_sender_not_null",
      "canonical_sender_address IS NOT NULL"
    )

    execute("ALTER TABLE provider_submissions ALTER COLUMN canonical_sender_address SET NOT NULL")

    execute(
      "ALTER TABLE provider_submissions DROP CONSTRAINT provider_submissions_canonical_sender_not_null"
    )

    add_validated_check(
      "provider_submissions_render_version_positive",
      "render_version IS NULL OR render_version > 0"
    )

    replace_validated_check(
      "provider_submissions_provider_valid",
      "provider IN ('resend', 'gmail', 'smtp', 'microsoft')"
    )

    replace_validated_check(
      "provider_submissions_method_shape_valid",
      """
      (provider = 'resend' AND send_method_id IS NULL AND idempotency_expires_at IS NOT NULL)
      OR
      (provider IN ('gmail', 'smtp', 'microsoft') AND send_method_id IS NOT NULL
       AND idempotency_expires_at IS NULL)
      """
    )

    replace_validated_method_foreign_key()
    install_snapshot_trigger()
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM provider_submissions WHERE provider = 'microsoft') THEN
        RAISE EXCEPTION 'cannot rollback Microsoft provider payloads while Microsoft submissions exist';
      END IF;
    END
    $$
    """)

    flush()

    execute("DROP TRIGGER IF EXISTS provider_submissions_freeze_snapshot ON provider_submissions")

    execute("DROP FUNCTION IF EXISTS provider_submissions_snapshot_immutable()")

    replace_validated_check(
      "provider_submissions_provider_valid",
      "provider IN ('resend', 'gmail', 'smtp')"
    )

    replace_validated_check(
      "provider_submissions_method_shape_valid",
      """
      (provider = 'resend' AND send_method_id IS NULL AND idempotency_expires_at IS NOT NULL)
      OR
      (provider IN ('gmail', 'smtp') AND send_method_id IS NOT NULL
       AND idempotency_expires_at IS NULL)
      """
    )

    replace_validated_method_foreign_key()

    execute(
      "ALTER TABLE provider_submissions DROP CONSTRAINT IF EXISTS provider_submissions_render_version_positive"
    )

    execute("ALTER TABLE provider_submissions DROP COLUMN IF EXISTS request_payload")
    execute("ALTER TABLE provider_submissions DROP COLUMN IF EXISTS render_version")
    execute("ALTER TABLE provider_submissions DROP COLUMN IF EXISTS canonical_sender_address")
  end

  defp backfill_canonical_senders! do
    result =
      repo().query!("""
      WITH batch AS (
        SELECT submission.id
        FROM provider_submissions AS submission
        WHERE submission.canonical_sender_address IS NULL
        ORDER BY submission.id
        LIMIT #{@backfill_batch_size}
      )
      UPDATE provider_submissions AS submission
      SET canonical_sender_address = outbound.canonical_sender_address
      FROM outbound_messages AS outbound, batch
      WHERE submission.id = batch.id
        AND outbound.id = submission.outbound_message_id
      """)

    if result.num_rows == @backfill_batch_size, do: backfill_canonical_senders!()
  end

  defp add_validated_check(name, expression) do
    execute("ALTER TABLE provider_submissions DROP CONSTRAINT IF EXISTS #{name}")

    execute("""
    ALTER TABLE provider_submissions
    ADD CONSTRAINT #{name}
    CHECK (#{expression}) NOT VALID
    """)

    flush()
    execute("ALTER TABLE provider_submissions VALIDATE CONSTRAINT #{name}")
    flush()
  end

  defp replace_validated_check(name, expression) do
    staged_name = "#{name}_staged"
    add_validated_check(staged_name, expression)
    execute("ALTER TABLE provider_submissions DROP CONSTRAINT IF EXISTS #{name}")

    execute("ALTER TABLE provider_submissions RENAME CONSTRAINT #{staged_name} TO #{name}")

    flush()
  end

  defp replace_validated_method_foreign_key do
    name = "provider_submissions_send_method_provider_fkey"
    staged_name = "#{name}_staged"

    execute("ALTER TABLE provider_submissions DROP CONSTRAINT IF EXISTS #{staged_name}")

    execute("""
    ALTER TABLE provider_submissions
    ADD CONSTRAINT #{staged_name}
    FOREIGN KEY (send_method_id, provider)
    REFERENCES connector_send_methods (id, kind)
    MATCH SIMPLE
    ON DELETE RESTRICT
    NOT VALID
    """)

    flush()
    execute("ALTER TABLE provider_submissions VALIDATE CONSTRAINT #{staged_name}")
    flush()
    execute("ALTER TABLE provider_submissions DROP CONSTRAINT IF EXISTS #{name}")

    execute("ALTER TABLE provider_submissions RENAME CONSTRAINT #{staged_name} TO #{name}")

    flush()
  end

  defp install_snapshot_trigger do
    execute("""
    CREATE OR REPLACE FUNCTION provider_submissions_snapshot_immutable()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.outbound_message_id IS DISTINCT FROM OLD.outbound_message_id
         OR NEW.send_method_id IS DISTINCT FROM OLD.send_method_id
         OR NEW.provider IS DISTINCT FROM OLD.provider
         OR NEW.canonical_sender_address IS DISTINCT FROM OLD.canonical_sender_address
         OR NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key
         OR NEW.request_sha256 IS DISTINCT FROM OLD.request_sha256
         OR NEW.provider_rfc_message_id IS DISTINCT FROM OLD.provider_rfc_message_id THEN
        RAISE EXCEPTION 'provider submission snapshot is immutable' USING ERRCODE = '23514';
      END IF;

      IF NEW.request_payload IS NOT DISTINCT FROM OLD.request_payload
         AND NEW.render_version IS NOT DISTINCT FROM OLD.render_version THEN
        RETURN NEW;
      END IF;

      IF OLD.provider IN ('gmail', 'smtp')
         AND OLD.request_payload IS NULL
         AND OLD.render_version IS NULL
         AND NEW.request_payload IS NOT NULL
         AND NEW.render_version > 0 THEN
        RETURN NEW;
      END IF;

      RAISE EXCEPTION 'provider submission snapshot is immutable' USING ERRCODE = '23514';
    END
    $$
    """)

    execute("DROP TRIGGER IF EXISTS provider_submissions_freeze_snapshot ON provider_submissions")

    execute("""
    CREATE TRIGGER provider_submissions_freeze_snapshot
    BEFORE UPDATE ON provider_submissions
    FOR EACH ROW
    EXECUTE FUNCTION provider_submissions_snapshot_immutable()
    """)
  end
end

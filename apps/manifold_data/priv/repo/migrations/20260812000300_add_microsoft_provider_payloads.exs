defmodule Manifold.Repo.Migrations.AddMicrosoftProviderPayloads do
  use Ecto.Migration

  def up do
    alter table(:provider_submissions) do
      add(:canonical_sender_address, :text)
      add(:render_version, :integer)
      add(:request_payload, :binary)
    end

    execute("""
    UPDATE provider_submissions AS submission
    SET canonical_sender_address = outbound.canonical_sender_address
    FROM outbound_messages AS outbound
    WHERE outbound.id = submission.outbound_message_id
    """)

    execute("ALTER TABLE provider_submissions ALTER COLUMN canonical_sender_address SET NOT NULL")

    create(
      constraint(:provider_submissions, :provider_submissions_render_version_positive,
        check: "render_version IS NULL OR render_version > 0"
      )
    )

    execute("""
    ALTER TABLE provider_submissions
    DROP CONSTRAINT IF EXISTS provider_submissions_send_method_provider_fkey
    """)

    drop(constraint(:provider_submissions, :provider_submissions_method_shape_valid))
    drop(constraint(:provider_submissions, :provider_submissions_provider_valid))

    create(
      constraint(:provider_submissions, :provider_submissions_provider_valid,
        check: "provider IN ('resend', 'gmail', 'smtp', 'microsoft')"
      )
    )

    create(
      constraint(:provider_submissions, :provider_submissions_method_shape_valid,
        check: """
        (provider = 'resend' AND send_method_id IS NULL AND idempotency_expires_at IS NOT NULL)
        OR
        (provider IN ('gmail', 'smtp', 'microsoft') AND send_method_id IS NOT NULL
         AND idempotency_expires_at IS NULL)
        """
      )
    )

    execute("""
    ALTER TABLE provider_submissions
    ADD CONSTRAINT provider_submissions_send_method_provider_fkey
    FOREIGN KEY (send_method_id, provider)
    REFERENCES connector_send_methods (id, kind)
    MATCH SIMPLE
    ON DELETE RESTRICT
    """)
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

    execute("""
    ALTER TABLE provider_submissions
    DROP CONSTRAINT IF EXISTS provider_submissions_send_method_provider_fkey
    """)

    drop(constraint(:provider_submissions, :provider_submissions_method_shape_valid))
    drop(constraint(:provider_submissions, :provider_submissions_provider_valid))
    drop(constraint(:provider_submissions, :provider_submissions_render_version_positive))

    create(
      constraint(:provider_submissions, :provider_submissions_provider_valid,
        check: "provider IN ('resend', 'gmail', 'smtp')"
      )
    )

    create(
      constraint(:provider_submissions, :provider_submissions_method_shape_valid,
        check: """
        (provider = 'resend' AND send_method_id IS NULL AND idempotency_expires_at IS NOT NULL)
        OR
        (provider IN ('gmail', 'smtp') AND send_method_id IS NOT NULL
         AND idempotency_expires_at IS NULL)
        """
      )
    )

    execute("""
    ALTER TABLE provider_submissions
    ADD CONSTRAINT provider_submissions_send_method_provider_fkey
    FOREIGN KEY (send_method_id, provider)
    REFERENCES connector_send_methods (id, kind)
    MATCH SIMPLE
    ON DELETE RESTRICT
    """)

    alter table(:provider_submissions) do
      remove(:request_payload)
      remove(:render_version)
      remove(:canonical_sender_address)
    end
  end
end

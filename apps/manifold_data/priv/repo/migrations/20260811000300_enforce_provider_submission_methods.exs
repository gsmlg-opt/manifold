defmodule Manifold.Repo.Migrations.EnforceProviderSubmissionMethods do
  use Ecto.Migration

  def up do
    create(
      unique_index(:connector_send_methods, [:id, :kind],
        name: :connector_send_methods_id_kind_index
      )
    )

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
        (provider IN ('gmail', 'smtp') AND send_method_id IS NOT NULL AND idempotency_expires_at IS NULL)
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
    ALTER TABLE provider_submissions
    DROP CONSTRAINT IF EXISTS provider_submissions_send_method_provider_fkey
    """)

    drop(constraint(:provider_submissions, :provider_submissions_method_shape_valid))
    drop(constraint(:provider_submissions, :provider_submissions_provider_valid))

    drop(
      index(:connector_send_methods, [:id, :kind], name: :connector_send_methods_id_kind_index)
    )
  end
end

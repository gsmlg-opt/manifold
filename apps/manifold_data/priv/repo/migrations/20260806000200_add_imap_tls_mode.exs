defmodule Manifold.Repo.Migrations.AddImapTlsMode do
  use Ecto.Migration

  def up do
    drop(constraint(:connector_imap_settings, :connector_imap_settings_tls_mode_valid))

    create(
      constraint(:connector_imap_settings, :connector_imap_settings_tls_mode_valid,
        check: "tls_mode IN ('ssl', 'tls', 'starttls')"
      )
    )
  end

  def down do
    execute("UPDATE connector_imap_settings SET tls_mode = 'ssl' WHERE tls_mode = 'tls'")

    drop(constraint(:connector_imap_settings, :connector_imap_settings_tls_mode_valid))

    create(
      constraint(:connector_imap_settings, :connector_imap_settings_tls_mode_valid,
        check: "tls_mode IN ('ssl', 'starttls')"
      )
    )
  end
end

defmodule Manifold.Repo.Migrations.AddSharedGmailAuthorizations do
  use Ecto.Migration

  # NON-ROLLING CUTOVER: Fully drain old app instances, Oban jobs, and connector workers
  # before running either direction. The up migration deletes migrated legacy credentials,
  # so old and new code must never run concurrently during this cutover.
  def up do
    preflight_legacy_gmail_receive_methods!()

    create table(:connector_oauth_authorizations, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:legacy_credential_id, :binary_id)
      add(:legacy_credential_password_ciphertext, :binary)

      add(:mailbox_id, references(:mailboxes, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:provider, :text, null: false)
      add(:provider_subject_id, :text, null: false)
      add(:email_address, :text, null: false)
      add(:granted_scopes, {:array, :text}, null: false, default: [])
      add(:status, :text, null: false, default: "connected")
      add(:key_version, :integer, null: false, default: 1)
      add(:access_token_ciphertext, :binary)
      add(:refresh_token_ciphertext, :binary)
      add(:token_expires_at, :utc_datetime_usec)
      add(:last_error_class, :text)
      add(:last_error_code, :text)
      add(:last_error_message, :text)
      add(:disconnected_at, :utc_datetime_usec)
      add(:lock_version, :integer, null: false, default: 1)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:connector_oauth_authorizations, [:mailbox_id, :provider],
        name: :connector_oauth_authorizations_mailbox_id_provider_index
      )
    )

    create(
      unique_index(:connector_oauth_authorizations, [:provider, :provider_subject_id],
        name: :connector_oauth_authorizations_provider_subject_index
      )
    )

    create(
      constraint(:connector_oauth_authorizations, :oauth_authorizations_provider_valid,
        check: "provider IN ('gmail')"
      )
    )

    create(
      constraint(:connector_oauth_authorizations, :oauth_authorizations_status_valid,
        check: "status IN ('connected', 'reconnect_required', 'disconnected')"
      )
    )

    create(
      constraint(
        :connector_oauth_authorizations,
        :oauth_authorizations_connected_refresh_required,
        check: "status <> 'connected' OR refresh_token_ciphertext IS NOT NULL"
      )
    )

    alter table(:connector_accounts) do
      add(
        :oauth_authorization_id,
        references(:connector_oauth_authorizations, type: :binary_id, on_delete: :restrict)
      )
    end

    alter table(:connector_send_methods) do
      add(
        :oauth_authorization_id,
        references(:connector_oauth_authorizations, type: :binary_id, on_delete: :restrict)
      )
    end

    alter table(:connector_oauth_transactions) do
      add(:purpose, :text, null: false, default: "receive")
      add(:required_scopes, {:array, :text}, null: false, default: [])
    end

    create(
      constraint(:connector_oauth_transactions, :connector_oauth_transactions_provider_valid,
        check: "provider IN ('gmail', 'microsoft')"
      )
    )

    create(
      constraint(:connector_oauth_transactions, :connector_oauth_transactions_purpose_valid,
        check: "purpose IN ('receive', 'send')"
      )
    )

    alter table(:provider_submissions) do
      add(
        :send_method_id,
        references(:connector_send_methods, type: :binary_id, on_delete: :restrict)
      )

      modify(:idempotency_expires_at, :utc_datetime_usec,
        null: true,
        from: {:utc_datetime_usec, null: false}
      )
    end

    drop(constraint(:connector_send_methods, :connector_send_methods_kind_valid))

    create(
      constraint(:connector_send_methods, :connector_send_methods_kind_valid,
        check: "kind IN ('smtp', 'gmail')"
      )
    )

    execute("""
    INSERT INTO connector_oauth_authorizations (
      id,
      legacy_credential_id,
      legacy_credential_password_ciphertext,
      mailbox_id,
      provider,
      provider_subject_id,
      email_address,
      granted_scopes,
      status,
      key_version,
      access_token_ciphertext,
      refresh_token_ciphertext,
      token_expires_at,
      last_error_class,
      last_error_code,
      last_error_message,
      disconnected_at,
      lock_version,
      inserted_at,
      updated_at
    )
    SELECT
      connector_account.id,
      credential.id,
      credential.password_ciphertext,
      connector_account.mailbox_id,
      'gmail',
      connector_account.provider_account_id,
      connector_account.email_address,
      connector_account.granted_scopes,
      CASE
        WHEN connector_account.status = 'disconnected' THEN 'disconnected'
        WHEN connector_account.status = 'reconnect_required'
          OR credential.refresh_token_ciphertext IS NULL
          THEN 'reconnect_required'
        ELSE 'connected'
      END,
      COALESCE(credential.key_version, 1),
      credential.access_token_ciphertext,
      credential.refresh_token_ciphertext,
      credential.token_expires_at,
      connector_account.last_error_class,
      connector_account.last_error_code,
      connector_account.last_error_message,
      connector_account.disconnected_at,
      COALESCE(credential.lock_version, connector_account.lock_version, 1),
      COALESCE(credential.inserted_at, connector_account.inserted_at),
      COALESCE(credential.updated_at, connector_account.updated_at)
    FROM connector_accounts AS connector_account
    LEFT JOIN connector_credentials AS credential
      ON credential.external_account_id = connector_account.id
      AND credential.secret_kind = 'oauth'
    WHERE connector_account.provider = 'gmail'
    """)

    execute("""
    UPDATE connector_accounts AS connector_account
    SET oauth_authorization_id = oauth_authorization.id
    FROM connector_oauth_authorizations AS oauth_authorization
    WHERE connector_account.id = oauth_authorization.id
      AND connector_account.provider = 'gmail'
    """)

    execute("""
    DELETE FROM connector_credentials AS credential
    USING connector_accounts AS connector_account
    WHERE credential.external_account_id = connector_account.id
      AND credential.secret_kind = 'oauth'
      AND connector_account.provider = 'gmail'
      AND connector_account.oauth_authorization_id = connector_account.id
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM connector_send_methods WHERE kind = 'gmail') THEN
        RAISE EXCEPTION 'cannot rollback shared Gmail authorizations while Gmail send methods exist';
      END IF;
    END
    $$
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM connector_oauth_authorizations AS oauth_authorization
        WHERE oauth_authorization.provider = 'gmail'
          AND (
            oauth_authorization.legacy_credential_id IS NOT NULL
            OR oauth_authorization.refresh_token_ciphertext IS NOT NULL
          )
          AND NOT EXISTS (
            SELECT 1
            FROM connector_accounts AS connector_account
            WHERE connector_account.id = oauth_authorization.id
          )
      ) THEN
        RAISE EXCEPTION
          'cannot rollback shared Gmail authorizations because the original connector account is missing';
      END IF;
    END
    $$
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM connector_oauth_authorizations AS oauth_authorization
        WHERE oauth_authorization.provider = 'gmail'
          AND oauth_authorization.legacy_credential_id IS NULL
          AND oauth_authorization.refresh_token_ciphertext IS NULL
          AND (
            oauth_authorization.access_token_ciphertext IS NOT NULL
            OR oauth_authorization.legacy_credential_password_ciphertext IS NOT NULL
          )
      ) THEN
        RAISE EXCEPTION
          'cannot rollback shared Gmail authorizations because token material cannot satisfy the legacy OAuth credential constraint';
      END IF;
    END
    $$
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM connector_oauth_authorizations AS oauth_authorization
        JOIN connector_credentials AS credential
          ON credential.id = COALESCE(
            oauth_authorization.legacy_credential_id,
            oauth_authorization.id
          )
          OR credential.external_account_id = oauth_authorization.id
        WHERE oauth_authorization.provider = 'gmail'
          AND (
            oauth_authorization.legacy_credential_id IS NOT NULL
            OR oauth_authorization.refresh_token_ciphertext IS NOT NULL
          )
      ) THEN
        RAISE EXCEPTION
          'cannot rollback shared Gmail authorizations because credential restoration would conflict';
      END IF;
    END
    $$
    """)

    execute("""
    INSERT INTO connector_credentials (
      id,
      external_account_id,
      key_version,
      secret_kind,
      access_token_ciphertext,
      refresh_token_ciphertext,
      password_ciphertext,
      token_expires_at,
      lock_version,
      inserted_at,
      updated_at
    )
    SELECT
      COALESCE(oauth_authorization.legacy_credential_id, oauth_authorization.id),
      oauth_authorization.id,
      oauth_authorization.key_version,
      'oauth',
      oauth_authorization.access_token_ciphertext,
      oauth_authorization.refresh_token_ciphertext,
      oauth_authorization.legacy_credential_password_ciphertext,
      oauth_authorization.token_expires_at,
      oauth_authorization.lock_version,
      oauth_authorization.inserted_at,
      oauth_authorization.updated_at
    FROM connector_oauth_authorizations AS oauth_authorization
    WHERE oauth_authorization.provider = 'gmail'
      AND (
        oauth_authorization.legacy_credential_id IS NOT NULL
        OR oauth_authorization.refresh_token_ciphertext IS NOT NULL
      )
    """)

    execute("""
    UPDATE provider_submissions
    SET idempotency_expires_at = COALESCE(inserted_at, NOW())
    WHERE idempotency_expires_at IS NULL
    """)

    drop(constraint(:connector_send_methods, :connector_send_methods_kind_valid))

    create(
      constraint(:connector_send_methods, :connector_send_methods_kind_valid,
        check: "kind IN ('smtp')"
      )
    )

    alter table(:provider_submissions) do
      remove(:send_method_id)

      modify(:idempotency_expires_at, :utc_datetime_usec,
        null: false,
        from: {:utc_datetime_usec, null: true}
      )
    end

    drop(constraint(:connector_oauth_transactions, :connector_oauth_transactions_purpose_valid))

    drop(constraint(:connector_oauth_transactions, :connector_oauth_transactions_provider_valid))

    alter table(:connector_oauth_transactions) do
      remove(:required_scopes)
      remove(:purpose)
    end

    alter table(:connector_send_methods) do
      remove(:oauth_authorization_id)
    end

    alter table(:connector_accounts) do
      remove(:oauth_authorization_id)
    end

    drop(table(:connector_oauth_authorizations))
  end

  defp preflight_legacy_gmail_receive_methods! do
    case repo().query!("""
         SELECT mailbox_id::text, provider, COUNT(*)
         FROM connector_accounts
         WHERE provider = 'gmail'
         GROUP BY mailbox_id, provider
         HAVING COUNT(*) > 1
         ORDER BY mailbox_id, provider
         LIMIT 1
         """).rows do
      [[mailbox_id, "gmail", count]] ->
        raise """
        cannot migrate shared Gmail authorizations: mailbox #{mailbox_id} has #{count} legacy Gmail receive methods; resolve the duplicate receive methods explicitly before retrying
        """

      [] ->
        :ok
    end

    rows =
      repo().query!("""
      SELECT
        connector_account.id::text,
        connector_account.mailbox_id::text,
        connector_account.email_address,
        mailbox.local_part || '@' || domain.normalized_domain
      FROM connector_accounts AS connector_account
      JOIN mailboxes AS mailbox ON mailbox.id = connector_account.mailbox_id
      JOIN domains AS domain ON domain.id = mailbox.domain_id
      WHERE connector_account.provider = 'gmail'
      ORDER BY connector_account.id
      """).rows

    Enum.each(rows, &preflight_legacy_gmail_address!/1)
  end

  defp preflight_legacy_gmail_address!([
         receive_method_id,
         mailbox_id,
         provider_address,
         mailbox_address
       ]) do
    with {:ok, provider_canonical} <- canonical_address(provider_address),
         {:ok, mailbox_canonical} <- canonical_address(mailbox_address),
         true <- provider_canonical == mailbox_canonical do
      :ok
    else
      _ ->
        raise """
        cannot migrate shared Gmail authorizations: legacy Gmail receive method #{receive_method_id} has provider address #{inspect(provider_address)} that does not match mailbox #{mailbox_id} address #{inspect(mailbox_address)}; reconnect or correct the receive method explicitly before retrying
        """
    end
  end

  # Keep migration-time comparison aligned with the application's exact address
  # contract: ASCII syntax validation, path unwrapping, and ASCII case folding only.
  defp canonical_address(address) do
    case Manifold.Core.Address.parse(address) do
      {:ok, %{canonical: canonical}} -> {:ok, canonical}
      {:error, _error} -> :error
    end
  end
end

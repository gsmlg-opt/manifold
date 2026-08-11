defmodule Manifold.Repo.Migrations.AddSharedMicrosoftAuthorizations do
  use Ecto.Migration

  # NON-ROLLING CUTOVER: Fully drain old app instances, Oban jobs, and connector workers
  # before running either direction. The up migration deletes migrated legacy credentials,
  # so old and new code must never run concurrently during this cutover.
  def up do
    preflight_legacy_microsoft_receive_methods!()

    drop(constraint(:connector_oauth_authorizations, :oauth_authorizations_provider_valid))

    create(
      constraint(:connector_oauth_authorizations, :oauth_authorizations_provider_valid,
        check: "provider IN ('gmail', 'microsoft')"
      )
    )

    drop(constraint(:connector_send_methods, :connector_send_methods_kind_valid))

    create(
      constraint(:connector_send_methods, :connector_send_methods_kind_valid,
        check: "kind IN ('smtp', 'gmail', 'microsoft')"
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
      receive_method.id,
      credential.id,
      credential.password_ciphertext,
      receive_method.mailbox_id,
      'microsoft',
      receive_method.provider_account_id,
      receive_method.email_address,
      ARRAY(
        SELECT DISTINCT scope
        FROM unnest(receive_method.granted_scopes) AS scope
        ORDER BY scope
      ),
      CASE
        WHEN receive_method.status = 'disconnected' THEN 'disconnected'
        WHEN receive_method.status = 'reconnect_required'
          OR credential.refresh_token_ciphertext IS NULL
          THEN 'reconnect_required'
        ELSE 'connected'
      END,
      COALESCE(credential.key_version, 1),
      credential.access_token_ciphertext,
      credential.refresh_token_ciphertext,
      credential.token_expires_at,
      receive_method.last_error_class,
      receive_method.last_error_code,
      receive_method.last_error_message,
      receive_method.disconnected_at,
      COALESCE(credential.lock_version, receive_method.lock_version, 1),
      COALESCE(credential.inserted_at, receive_method.inserted_at),
      COALESCE(credential.updated_at, receive_method.updated_at)
    FROM connector_accounts AS receive_method
    LEFT JOIN connector_credentials AS credential
      ON credential.external_account_id = receive_method.id
      AND credential.secret_kind = 'oauth'
    WHERE receive_method.provider = 'microsoft'
    """)

    execute("""
    UPDATE connector_accounts AS receive_method
    SET oauth_authorization_id = oauth_authorization.id
    FROM connector_oauth_authorizations AS oauth_authorization
    WHERE oauth_authorization.id = receive_method.id
      AND oauth_authorization.provider = 'microsoft'
      AND receive_method.provider = 'microsoft'
    """)

    execute("""
    UPDATE connector_events AS event
    SET oauth_authorization_id = receive_method.oauth_authorization_id,
        external_account_id = NULL
    FROM connector_accounts AS receive_method
    WHERE event.external_account_id = receive_method.id
      AND receive_method.provider = 'microsoft'
      AND receive_method.oauth_authorization_id IS NOT NULL
    """)

    execute("""
    DELETE FROM connector_credentials AS credential
    USING connector_accounts AS receive_method
    WHERE credential.external_account_id = receive_method.id
      AND credential.secret_kind = 'oauth'
      AND receive_method.provider = 'microsoft'
      AND receive_method.oauth_authorization_id = receive_method.id
    """)
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM connector_send_methods WHERE kind = 'microsoft') THEN
        RAISE EXCEPTION
          'cannot rollback shared Microsoft authorizations while Microsoft send methods exist';
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
        WHERE oauth_authorization.provider = 'microsoft'
          AND (
            (
              SELECT count(*)
              FROM connector_accounts AS receive_method
              WHERE receive_method.oauth_authorization_id = oauth_authorization.id
            ) <> 1
            OR NOT EXISTS (
              SELECT 1
              FROM connector_accounts AS receive_method
              WHERE receive_method.id = oauth_authorization.id
                AND receive_method.oauth_authorization_id = oauth_authorization.id
                AND receive_method.provider = 'microsoft'
            )
          )
      ) THEN
        RAISE EXCEPTION
          'cannot rollback shared Microsoft authorizations without exactly one original Microsoft receive method';
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
        WHERE oauth_authorization.provider = 'microsoft'
          AND oauth_authorization.refresh_token_ciphertext IS NULL
          AND (
            oauth_authorization.legacy_credential_id IS NOT NULL
            OR oauth_authorization.access_token_ciphertext IS NOT NULL
            OR oauth_authorization.legacy_credential_password_ciphertext IS NOT NULL
          )
      ) THEN
        RAISE EXCEPTION
          'cannot rollback shared Microsoft authorizations because token material cannot satisfy the legacy OAuth credential constraint';
      END IF;
    END
    $$
    """)

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT COALESCE(oauth_authorization.legacy_credential_id, oauth_authorization.id)
        FROM connector_oauth_authorizations AS oauth_authorization
        WHERE oauth_authorization.provider = 'microsoft'
          AND (
            oauth_authorization.legacy_credential_id IS NOT NULL
            OR oauth_authorization.refresh_token_ciphertext IS NOT NULL
          )
        GROUP BY COALESCE(
          oauth_authorization.legacy_credential_id,
          oauth_authorization.id
        )
        HAVING COUNT(*) > 1
      ) OR EXISTS (
        SELECT 1
        FROM connector_oauth_authorizations AS oauth_authorization
        JOIN connector_accounts AS receive_method
          ON receive_method.id = oauth_authorization.id
          AND receive_method.oauth_authorization_id = oauth_authorization.id
          AND receive_method.provider = 'microsoft'
        JOIN connector_credentials AS credential
          ON credential.id = COALESCE(
            oauth_authorization.legacy_credential_id,
            oauth_authorization.id
          )
          OR credential.external_account_id = receive_method.id
        WHERE oauth_authorization.provider = 'microsoft'
          AND (
            oauth_authorization.legacy_credential_id IS NOT NULL
            OR oauth_authorization.refresh_token_ciphertext IS NOT NULL
          )
      ) THEN
        RAISE EXCEPTION
          'cannot rollback shared Microsoft authorizations because credential restoration would conflict';
      END IF;
    END
    $$
    """)

    execute("""
    UPDATE connector_events AS event
    SET external_account_id = receive_method.id,
        oauth_authorization_id = NULL
    FROM connector_oauth_authorizations AS oauth_authorization
    JOIN connector_accounts AS receive_method
      ON receive_method.id = oauth_authorization.id
      AND receive_method.oauth_authorization_id = oauth_authorization.id
      AND receive_method.provider = 'microsoft'
    WHERE event.oauth_authorization_id = oauth_authorization.id
      AND oauth_authorization.provider = 'microsoft'
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
      receive_method.id,
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
    JOIN connector_accounts AS receive_method
      ON receive_method.id = oauth_authorization.id
      AND receive_method.oauth_authorization_id = oauth_authorization.id
      AND receive_method.provider = 'microsoft'
    WHERE oauth_authorization.provider = 'microsoft'
      AND (
        oauth_authorization.legacy_credential_id IS NOT NULL
        OR oauth_authorization.refresh_token_ciphertext IS NOT NULL
      )
    """)

    execute("""
    UPDATE connector_accounts AS receive_method
    SET oauth_authorization_id = NULL
    FROM connector_oauth_authorizations AS oauth_authorization
    WHERE receive_method.id = oauth_authorization.id
      AND receive_method.oauth_authorization_id = oauth_authorization.id
      AND receive_method.provider = 'microsoft'
      AND oauth_authorization.provider = 'microsoft'
    """)

    execute("""
    DELETE FROM connector_oauth_authorizations
    WHERE provider = 'microsoft'
    """)

    drop(constraint(:connector_oauth_authorizations, :oauth_authorizations_provider_valid))

    create(
      constraint(:connector_oauth_authorizations, :oauth_authorizations_provider_valid,
        check: "provider IN ('gmail')"
      )
    )

    drop(constraint(:connector_send_methods, :connector_send_methods_kind_valid))

    create(
      constraint(:connector_send_methods, :connector_send_methods_kind_valid,
        check: "kind IN ('smtp', 'gmail')"
      )
    )
  end

  defp preflight_legacy_microsoft_receive_methods! do
    duplicate =
      repo().query!("""
      SELECT mailbox_id::text, COUNT(*)
      FROM connector_accounts
      WHERE provider = 'microsoft'
      GROUP BY mailbox_id
      HAVING COUNT(*) > 1
      ORDER BY mailbox_id
      LIMIT 1
      """).rows

    case duplicate do
      [[mailbox_id, count]] ->
        raise "cannot migrate shared Microsoft authorizations: mailbox #{mailbox_id} has #{count} Microsoft receive methods"

      [] ->
        :ok
    end

    mismatch =
      repo().query!("""
      SELECT receive_method.id::text, receive_method.email_address,
             mailbox.local_part || '@' || domain.normalized_domain
      FROM connector_accounts AS receive_method
      JOIN mailboxes AS mailbox ON mailbox.id = receive_method.mailbox_id
      JOIN domains AS domain ON domain.id = mailbox.domain_id
      WHERE receive_method.provider = 'microsoft'
        AND lower(receive_method.email_address) <>
            lower(mailbox.local_part || '@' || domain.normalized_domain)
      ORDER BY receive_method.id
      LIMIT 1
      """).rows

    case mismatch do
      [[method_id, _provider_address, _account_address]] ->
        raise "cannot migrate Microsoft receive method #{method_id}: canonical address mismatch"

      [] ->
        :ok
    end
  end
end

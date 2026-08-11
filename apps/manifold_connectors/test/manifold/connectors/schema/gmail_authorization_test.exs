defmodule Manifold.Connectors.Schema.GmailAuthorizationTest do
  use ExUnit.Case, async: true

  alias Manifold.Connectors.GmailScopes

  alias Manifold.Connectors.Schema.{
    OAuthAuthorization,
    OAuthTransaction,
    ReceiveMethod,
    SendMethod
  }

  alias Manifold.Outbound.Schema.ProviderSubmission

  test "Gmail authorization accepts identity, canonical address, scopes, and tokens" do
    changeset =
      authorization_changeset(%{
        granted_scopes: [GmailScopes.send(), GmailScopes.read(), GmailScopes.send()]
      })

    assert changeset.valid?

    assert Ecto.Changeset.get_field(changeset, :granted_scopes) == [
             GmailScopes.read(),
             GmailScopes.send()
           ]
  end

  test "Gmail authorization validates provider and status" do
    refute authorization_changeset(%{provider: "microsoft"}).valid?
    refute authorization_changeset(%{status: "failed"}).valid?

    for status <- ~w(connected reconnect_required disconnected) do
      assert authorization_changeset(%{status: status}).valid?
    end
  end

  test "only connected Gmail authorizations require a refresh token" do
    refute authorization_changeset(%{refresh_token_ciphertext: nil}).valid?

    for status <- ~w(reconnect_required disconnected) do
      assert authorization_changeset(%{
               status: status,
               refresh_token_ciphertext: nil
             }).valid?
    end
  end

  test "Gmail authorization rejects explicit nil scopes without raising" do
    changeset = authorization_changeset(%{granted_scopes: nil})

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:granted_scopes]
  end

  test "Gmail authorization validates address and error field lengths" do
    refute authorization_changeset(%{email_address: "x"}).valid?
    refute authorization_changeset(%{email_address: String.duplicate("x", 999)}).valid?
    refute authorization_changeset(%{last_error_class: String.duplicate("x", 256)}).valid?
    refute authorization_changeset(%{last_error_code: String.duplicate("x", 256)}).valid?
    refute authorization_changeset(%{last_error_message: String.duplicate("x", 1_001)}).valid?
  end

  test "Gmail authorization declares both named uniqueness constraints" do
    constraints =
      authorization_changeset()
      |> Map.fetch!(:constraints)
      |> Enum.map(&to_string(&1.constraint))

    assert "connector_oauth_authorizations_mailbox_id_provider_index" in constraints

    assert "connector_oauth_authorizations_provider_subject_index" in constraints
  end

  test "send methods accept Gmail, retain SMTP, and cast authorization IDs" do
    authorization_id = Ecto.UUID.generate()

    for kind <- ~w(gmail smtp) do
      changeset =
        SendMethod.changeset(%SendMethod{}, %{
          account_id: Ecto.UUID.generate(),
          oauth_authorization_id: authorization_id,
          kind: kind,
          email_address: "person@gmail.com",
          status: "connected",
          enabled: true
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :oauth_authorization_id) == authorization_id
    end
  end

  test "receive methods cast authorization IDs" do
    authorization_id = Ecto.UUID.generate()

    changeset =
      ReceiveMethod.changeset(%ReceiveMethod{}, %{
        account_id: Ecto.UUID.generate(),
        oauth_authorization_id: authorization_id,
        kind: "gmail",
        provider_account_id: "google-sub-1",
        email_address: "person@gmail.com",
        status: "connected",
        enabled: true,
        sync_enabled: true,
        granted_scopes: [GmailScopes.read()]
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :oauth_authorization_id) == authorization_id
  end

  test "OAuth transactions require a valid purpose and required scopes" do
    changeset =
      OAuthTransaction.changeset(%OAuthTransaction{}, oauth_transaction_attrs())

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :purpose) == "send"
    assert Ecto.Changeset.get_field(changeset, :required_scopes) == [GmailScopes.send()]

    refute OAuthTransaction.changeset(
             %OAuthTransaction{purpose: nil},
             Map.delete(oauth_transaction_attrs(), :purpose)
           ).valid?

    refute OAuthTransaction.changeset(
             %OAuthTransaction{},
             %{oauth_transaction_attrs() | purpose: "admin"}
           ).valid?

    refute OAuthTransaction.changeset(
             %OAuthTransaction{required_scopes: nil},
             Map.delete(oauth_transaction_attrs(), :required_scopes)
           ).valid?
  end

  test "OAuth transactions reject explicit nil scopes without raising" do
    changeset =
      OAuthTransaction.changeset(
        %OAuthTransaction{},
        %{oauth_transaction_attrs() | required_scopes: nil}
      )

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:required_scopes]
  end

  test "Gmail provider submissions accept nil Resend expiry and cast send method" do
    send_method_id = Ecto.UUID.generate()

    changeset =
      ProviderSubmission.changeset(%ProviderSubmission{}, %{
        outbound_message_id: Ecto.UUID.generate(),
        send_method_id: send_method_id,
        provider: "gmail",
        idempotency_key: Ecto.UUID.generate(),
        request_sha256: String.duplicate("a", 64),
        state: "pending",
        attempt_count: 0,
        idempotency_expires_at: nil
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :send_method_id) == send_method_id
  end

  test "legacy Resend provider submissions still require an idempotency expiry" do
    changeset =
      ProviderSubmission.changeset(%ProviderSubmission{}, %{
        outbound_message_id: Ecto.UUID.generate(),
        provider: "resend",
        idempotency_key: Ecto.UUID.generate(),
        request_sha256: String.duplicate("a", 64),
        state: "pending",
        attempt_count: 0,
        idempotency_expires_at: nil
      })

    refute changeset.valid?
    assert {"can't be blank", _} = changeset.errors[:idempotency_expires_at]
  end

  test "provider submissions enforce provider-specific method and expiry shape" do
    base = %{
      outbound_message_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      request_sha256: String.duplicate("a", 64),
      state: "pending",
      attempt_count: 0
    }

    refute ProviderSubmission.changeset(%ProviderSubmission{}, Map.put(base, :provider, "gmail")).valid?

    refute ProviderSubmission.changeset(
             %ProviderSubmission{},
             base
             |> Map.put(:provider, "resend")
             |> Map.put(:send_method_id, Ecto.UUID.generate())
             |> Map.put(:idempotency_expires_at, DateTime.utc_now())
           ).valid?

    refute ProviderSubmission.changeset(
             %ProviderSubmission{},
             base
             |> Map.put(:provider, "smtp")
             |> Map.put(:send_method_id, Ecto.UUID.generate())
             |> Map.put(:idempotency_expires_at, DateTime.utc_now())
           ).valid?

    refute ProviderSubmission.changeset(
             %ProviderSubmission{},
             Map.put(base, :provider, "unknown")
           ).valid?
  end

  defp authorization_changeset(overrides \\ %{}) do
    OAuthAuthorization.changeset(
      %OAuthAuthorization{},
      Map.merge(
        %{
          account_id: Ecto.UUID.generate(),
          provider: "gmail",
          provider_subject_id: "google-sub-1",
          email_address: "person@gmail.com",
          granted_scopes: ["openid", "email", GmailScopes.read()],
          status: "connected",
          key_version: 1,
          access_token_ciphertext: <<4, 5, 6>>,
          refresh_token_ciphertext: <<1, 2, 3>>,
          token_expires_at: DateTime.add(DateTime.utc_now(), 3_600)
        },
        overrides
      )
    )
  end

  defp oauth_transaction_attrs do
    %{
      state_digest: :crypto.strong_rand_bytes(32),
      provider: "gmail",
      mailbox_id: Ecto.UUID.generate(),
      purpose: "send",
      required_scopes: [GmailScopes.send()],
      pkce_verifier_ciphertext: <<1, 2, 3>>,
      redirect_uri: "https://mail.example.test/connectors/gmail/callback",
      expires_at: DateTime.add(DateTime.utc_now(), 600)
    }
  end
end

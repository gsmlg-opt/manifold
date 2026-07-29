defmodule Manifold.Connectors.OAuthTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors.OAuth
  alias Manifold.Connectors.Schema.OAuthTransaction
  alias Manifold.Repo

  setup do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_providers = Application.get_env(:manifold_connectors, :providers)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        client_id: "gmail-client",
        client_secret: "gmail-secret",
        authorization_url: "https://accounts.google.test/o/oauth2/v2/auth"
      ]
    )

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:providers, old_providers)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "oauth#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_mailbox(domain, %{local_part: "person"})
    {:ok, mailbox: mailbox}
  end

  test "starts a persisted PKCE authorization without storing plain state", %{mailbox: mailbox} do
    redirect_uri = "https://mail.example.test/connectors/gmail/callback"
    now = ~U[2026-07-29 01:00:00.000000Z]

    assert {:ok, authorization} =
             OAuth.start("gmail", mailbox.id, redirect_uri, now: now)

    assert byte_size(authorization.state) >= 43
    assert authorization.url =~ "code_challenge_method=S256"
    assert authorization.url =~ "access_type=offline"
    assert authorization.url =~ "prompt=consent"
    assert authorization.url =~ URI.encode_www_form(authorization.state)

    transaction = Repo.one!(OAuthTransaction)
    refute transaction.state_digest == authorization.state
    refute transaction.pkce_verifier_ciphertext =~ authorization.state
    assert transaction.redirect_uri == redirect_uri
    assert DateTime.compare(transaction.expires_at, now) == :gt
  end

  test "consumes matching OAuth state exactly once", %{mailbox: mailbox} do
    redirect_uri = "https://mail.example.test/connectors/gmail/callback"
    now = ~U[2026-07-29 01:00:00.000000Z]

    assert {:ok, authorization} =
             OAuth.start("gmail", mailbox.id, redirect_uri, now: now)

    assert {:ok, consumed} =
             OAuth.consume(
               "gmail",
               authorization.state,
               redirect_uri,
               now: DateTime.add(now, 60, :second)
             )

    assert consumed.mailbox_id == mailbox.id
    assert byte_size(consumed.pkce_verifier) >= 43

    assert {:error, %{class: :permanent, reason: :oauth_state_replayed}} =
             OAuth.consume(
               "gmail",
               authorization.state,
               redirect_uri,
               now: DateTime.add(now, 61, :second)
             )
  end

  test "rejects expired and redirect-mismatched OAuth state", %{mailbox: mailbox} do
    redirect_uri = "https://mail.example.test/connectors/gmail/callback"
    now = ~U[2026-07-29 01:00:00.000000Z]

    assert {:ok, authorization} =
             OAuth.start("gmail", mailbox.id, redirect_uri, now: now, ttl_seconds: 30)

    assert {:error, %{reason: :oauth_state_mismatch}} =
             OAuth.consume(
               "gmail",
               authorization.state,
               "https://other.example.test/callback",
               now: DateTime.add(now, 10, :second)
             )

    assert {:error, %{reason: :oauth_state_expired}} =
             OAuth.consume(
               "gmail",
               authorization.state,
               redirect_uri,
               now: DateTime.add(now, 31, :second)
             )
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

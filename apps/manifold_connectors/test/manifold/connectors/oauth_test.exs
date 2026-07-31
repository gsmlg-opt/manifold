defmodule Manifold.Connectors.OAuthTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors.OAuth
  alias Manifold.Connectors.Provider.{DeviceCode, Error, Token}
  alias Manifold.Connectors.Schema.OAuthTransaction
  alias Manifold.Repo

  defmodule FakeMicrosoft do
    @behaviour Manifold.Connectors.Provider

    @impl true
    def exchange_code(_code, _verifier, _redirect_uri, _config, _opts),
      do: {:error, %Error{class: :permanent, code: :unsupported, message: "not used"}}

    @impl true
    def request_device_code(_config, opts) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      {:ok,
       %DeviceCode{
         device_code: "device-secret",
         user_code: "WXYZ-1234",
         verification_uri: "https://login.microsoft.test/device",
         verification_uri_complete: nil,
         interval_seconds: 2,
         expires_at: DateTime.add(now, 120, :second)
       }}
    end

    @impl true
    def exchange_device_code("device-secret", _config, _opts) do
      case Application.get_env(:manifold_connectors, :oauth_test_poll, :token) do
        :pending ->
          {:pending, :authorization_pending}

        :slow_down ->
          {:pending, :slow_down, 5}

        :declined ->
          {:error,
           %Error{class: :permanent, code: :authorization_declined, message: "declined"}}

        :token ->
          {:ok,
           %Token{
             access_token: "access",
             refresh_token: "refresh",
             expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
             scopes: ["Mail.Read", "offline_access"]
           }}
      end
    end

    def exchange_device_code(_device_code, _config, _opts),
      do: {:error, %Error{class: :permanent, code: :invalid_grant, message: "bad code"}}

    @impl true
    def refresh_token(_refresh_token, _config, _opts), do: raise("not used")

    @impl true
    def identity(_token, _config, _opts), do: raise("not used")

    @impl true
    def initial_cursors(_token, _config, _opts), do: raise("not used")

    @impl true
    def sync_page(_token, _cursor, _config, _opts), do: raise("not used")

    @impl true
    def fetch_raw(_token, _id, _config, _opts), do: raise("not used")
  end

  setup do
    old_key = Application.get_env(:manifold_connectors, :encryption_key)
    old_providers = Application.get_env(:manifold_connectors, :providers)
    old_adapters = Application.get_env(:manifold_connectors, :adapters)

    Application.put_env(
      :manifold_connectors,
      :encryption_key,
      Base.encode64(:crypto.strong_rand_bytes(32))
    )

    Application.put_env(:manifold_connectors, :adapters, microsoft: FakeMicrosoft)

    Application.put_env(:manifold_connectors, :providers,
      gmail: [
        client_id: "gmail-client",
        authorization_url: "https://accounts.google.test/o/oauth2/v2/auth"
      ],
      microsoft: [
        client_id: "microsoft-client",
        device_code_url: "https://login.microsoft.test/devicecode",
        token_url: "https://login.microsoft.test/token"
      ]
    )

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:providers, old_providers)
      restore_env(:adapters, old_adapters)
      Application.delete_env(:manifold_connectors, :oauth_test_poll)
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
    assert transaction.flow == "authorization_code"
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

  test "rejects Microsoft authorization-code start", %{mailbox: mailbox} do
    assert {:error, %{reason: :authorization_code_unsupported}} =
             OAuth.start(
               "microsoft",
               mailbox.id,
               "https://mail.example.test/connectors/microsoft/callback"
             )
  end

  test "rejects Gmail device start", %{mailbox: mailbox} do
    assert {:error, %{reason: :device_flow_unsupported}} =
             OAuth.start_device("gmail", mailbox.id)
  end

  test "starts a device authorization and polls until a token is issued", %{mailbox: mailbox} do
    now = ~U[2026-07-31 01:00:00.000000Z]
    Application.put_env(:manifold_connectors, :oauth_test_poll, :pending)

    assert {:ok, authorization} =
             OAuth.start_device("microsoft", mailbox.id, now: now, provider_opts: [now: now])

    assert authorization.user_code == "WXYZ-1234"
    assert authorization.verification_uri == "https://login.microsoft.test/device"
    assert authorization.interval_seconds == 2

    transaction = Repo.one!(OAuthTransaction)
    assert transaction.flow == "device"
    assert transaction.user_code == "WXYZ-1234"
    refute is_nil(transaction.device_code_ciphertext)

    assert {:ok, :authorization_pending} =
             OAuth.poll_device("microsoft", authorization.state, now: DateTime.add(now, 1, :second))

    Application.put_env(:manifold_connectors, :oauth_test_poll, :slow_down)

    assert {:ok, {:slow_down, 5}} =
             OAuth.poll_device("microsoft", authorization.state, now: DateTime.add(now, 2, :second))

    Application.put_env(:manifold_connectors, :oauth_test_poll, :token)

    assert {:ok, %Token{access_token: "access"}, consumed} =
             OAuth.poll_device("microsoft", authorization.state, now: DateTime.add(now, 3, :second))

    assert consumed.mailbox_id == mailbox.id
    assert consumed.provider == "microsoft"

    assert {:error, %{reason: :oauth_state_replayed}} =
             OAuth.poll_device("microsoft", authorization.state, now: DateTime.add(now, 4, :second))
  end

  test "marks declined device authorizations as consumed", %{mailbox: mailbox} do
    now = ~U[2026-07-31 02:00:00.000000Z]
    Application.put_env(:manifold_connectors, :oauth_test_poll, :declined)

    assert {:ok, authorization} =
             OAuth.start_device("microsoft", mailbox.id, now: now, provider_opts: [now: now])

    assert {:error, %{reason: :authorization_declined}} =
             OAuth.poll_device("microsoft", authorization.state, now: DateTime.add(now, 1, :second))

    assert %OAuthTransaction{consumed_at: consumed_at} = Repo.one!(OAuthTransaction)
    refute is_nil(consumed_at)
  end

  defp restore_env(key, nil), do: Application.delete_env(:manifold_connectors, key)
  defp restore_env(key, value), do: Application.put_env(:manifold_connectors, key, value)
end

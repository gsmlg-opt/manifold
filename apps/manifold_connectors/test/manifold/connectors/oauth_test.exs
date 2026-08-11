defmodule Manifold.Connectors.OAuthTest do
  use Manifold.DataCase, async: false

  alias Manifold.Accounts
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.GmailScopes
  alias Manifold.Connectors.OAuth

  alias Manifold.Connectors.Schema.{OAuthAuthorization, OAuthTransaction}

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
      ],
      microsoft: [
        client_id: "microsoft-client",
        client_secret: "microsoft-secret",
        authorization_url: "https://login.microsoft.test/oauth2/v2.0/authorize"
      ]
    )

    on_exit(fn ->
      restore_env(:encryption_key, old_key)
      restore_env(:providers, old_providers)
    end)

    suffix = System.unique_integer([:positive])
    {:ok, domain} = Accounts.create_domain(%{name: "oauth#{suffix}.test"})
    {:ok, mailbox} = Accounts.create_account(domain, %{local_part: "person"})
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
    assert transaction.purpose == "receive"
    assert transaction.required_scopes == [GmailScopes.read()]
    assert DateTime.compare(transaction.expires_at, now) == :gt
  end

  test "legacy consumed struct construction has receive-safe defaults", %{mailbox: mailbox} do
    consumed = %OAuth.Consumed{
      provider: "gmail",
      mailbox_id: mailbox.id,
      redirect_uri: "https://mail.example.test/connectors/gmail/callback",
      pkce_verifier: "verifier"
    }

    assert consumed.purpose == :receive
    assert consumed.required_scopes == []
  end

  test "starts and consumes a Gmail send authorization with only the send provider scope", %{
    mailbox: mailbox
  } do
    redirect_uri = "https://mail.example.test/connectors/gmail/callback"

    assert {:ok, authorization} =
             OAuth.start("gmail", mailbox.id, redirect_uri, purpose: :send)

    assert authorization_scopes(authorization.url) == [
             "openid",
             "email",
             GmailScopes.send()
           ]

    refute GmailScopes.read() in authorization_scopes(authorization.url)

    transaction = Repo.one!(OAuthTransaction)
    assert transaction.purpose == "send"
    assert transaction.required_scopes == [GmailScopes.send()]

    assert {:ok, consumed} =
             OAuth.consume("gmail", authorization.state, redirect_uri)

    assert consumed.purpose == :send
    assert consumed.required_scopes == [GmailScopes.send()]
  end

  test "OAuth start telemetry reports sanitized success and failure outcomes", %{
    mailbox: mailbox
  } do
    handler_id = "oauth-start-telemetry-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :connectors, :oauth, :start, :stop],
        fn event, measurements, metadata, pid ->
          send(pid, {:telemetry, event, measurements, metadata})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _authorization} =
             OAuth.start(
               "gmail",
               mailbox.id,
               "https://mail.example.test/connectors/gmail/callback?secret=oauth-start-secret",
               purpose: :send
             )

    assert_receive {:telemetry, [:manifold, :connectors, :oauth, :start, :stop],
                    %{duration_ms: duration_ms, attempt_count: 1} = measurements,
                    %{
                      account_id: account_id,
                      provider: "gmail",
                      method_kind: "gmail",
                      outcome: :started
                    } = metadata}

    assert is_integer(duration_ms) and duration_ms >= 0
    assert account_id == mailbox.id

    assert_secret_free_telemetry(measurements, metadata, [
      "oauth-start-secret",
      "gmail-client",
      "gmail-secret"
    ])

    assert {:error, %{reason: :invalid_oauth_purpose}} =
             OAuth.start(
               "gmail",
               mailbox.id,
               "https://mail.example.test/connectors/gmail/callback?secret=oauth-failure-secret",
               purpose: :admin
             )

    assert_receive {:telemetry, [:manifold, :connectors, :oauth, :start, :stop],
                    %{duration_ms: failure_duration, attempt_count: 1} = failure_measurements,
                    %{
                      account_id: failure_account_id,
                      provider: "gmail",
                      method_kind: "gmail",
                      outcome: :error,
                      error_code: :invalid_oauth_purpose
                    } = failure_metadata}

    assert is_integer(failure_duration) and failure_duration >= 0
    assert failure_account_id == mailbox.id

    assert_secret_free_telemetry(failure_measurements, failure_metadata, [
      "oauth-failure-secret",
      "gmail-client",
      "gmail-secret"
    ])
  end

  test "starts and consumes an explicit Gmail receive authorization without the send scope", %{
    mailbox: mailbox
  } do
    redirect_uri = "https://mail.example.test/connectors/gmail/callback"

    assert {:ok, authorization} =
             OAuth.start("gmail", mailbox.id, redirect_uri, purpose: :receive)

    assert authorization_scopes(authorization.url) == [
             "openid",
             "email",
             GmailScopes.read()
           ]

    refute GmailScopes.send() in authorization_scopes(authorization.url)

    assert {:ok, consumed} =
             OAuth.consume("gmail", authorization.state, redirect_uri)

    assert consumed.purpose == :receive
    assert consumed.required_scopes == [GmailScopes.read()]
  end

  test "Gmail send authorization incrementally requests normalized existing provider scopes", %{
    mailbox: mailbox
  } do
    existing_provider_scope = "https://www.googleapis.com/auth/gmail.labels"

    insert_gmail_authorization!(mailbox.id, [
      "openid",
      existing_provider_scope,
      GmailScopes.read(),
      GmailScopes.read()
    ])

    redirect_uri = "https://mail.example.test/connectors/gmail/callback"

    assert {:ok, authorization} =
             OAuth.start("gmail", mailbox.id, redirect_uri, purpose: :send)

    required_scopes = Enum.sort([GmailScopes.read(), GmailScopes.send()])

    assert authorization_scopes(authorization.url) == ["openid", "email" | required_scopes]

    transaction = Repo.one!(OAuthTransaction)
    assert transaction.required_scopes == required_scopes

    assert {:ok, consumed} =
             OAuth.consume("gmail", authorization.state, redirect_uri)

    assert consumed.required_scopes == required_scopes
  end

  test "rejects unsupported Microsoft send purpose without creating a transaction", %{
    mailbox: mailbox
  } do
    assert {:error, %{class: :permanent, reason: :unsupported_oauth_purpose}} =
             OAuth.start(
               "microsoft",
               mailbox.id,
               "https://mail.example.test/connectors/microsoft/callback",
               purpose: :send
             )

    assert Repo.aggregate(OAuthTransaction, :count) == 0
  end

  test "keeps Microsoft receive scopes compatible by default", %{mailbox: mailbox} do
    redirect_uri = "https://mail.example.test/connectors/microsoft/callback"

    assert {:ok, authorization} = OAuth.start("microsoft", mailbox.id, redirect_uri)

    assert authorization_scopes(authorization.url) == [
             "openid",
             "profile",
             "User.Read",
             "Mail.Read",
             "offline_access"
           ]

    transaction = Repo.one!(OAuthTransaction)
    assert transaction.purpose == "receive"
    assert transaction.required_scopes == ["Mail.Read", "offline_access"]
  end

  test "consumes a legacy Gmail receive transaction with canonical scopes", %{
    mailbox: mailbox
  } do
    redirect_uri = "https://mail.example.test/connectors/gmail/callback"
    now = ~U[2026-08-11 01:00:00.000000Z]

    {state, verifier} =
      insert_legacy_transaction!("gmail", mailbox.id, redirect_uri, now)

    assert {:ok, consumed} =
             OAuth.consume("gmail", state, redirect_uri, now: DateTime.add(now, 60, :second))

    assert consumed.purpose == :receive
    assert consumed.required_scopes == [GmailScopes.read()]
    assert consumed.pkce_verifier == verifier
  end

  test "consumes a legacy Microsoft receive transaction with canonical scopes", %{
    mailbox: mailbox
  } do
    redirect_uri = "https://mail.example.test/connectors/microsoft/callback"
    now = ~U[2026-08-11 01:00:00.000000Z]

    {state, verifier} =
      insert_legacy_transaction!("microsoft", mailbox.id, redirect_uri, now)

    assert {:ok, consumed} =
             OAuth.consume("microsoft", state, redirect_uri, now: DateTime.add(now, 60, :second))

    assert consumed.purpose == :receive
    assert consumed.required_scopes == ["Mail.Read", "offline_access"]
    assert consumed.pkce_verifier == verifier
  end

  test "rejects invalid purpose without creating a transaction", %{mailbox: mailbox} do
    assert {:error, %{class: :permanent, reason: :invalid_oauth_purpose}} =
             OAuth.start(
               "gmail",
               mailbox.id,
               "https://mail.example.test/connectors/gmail/callback",
               purpose: :admin
             )

    assert Repo.aggregate(OAuthTransaction, :count) == 0
  end

  test "rejects a malformed account ID without creating a transaction" do
    assert {:error,
            %{
              class: :permanent,
              reason: :invalid_oauth_request,
              message: "OAuth request is invalid",
              details: %{}
            }} =
             OAuth.start(
               "gmail",
               "not-a-uuid",
               "https://mail.example.test/connectors/gmail/callback"
             )

    assert Repo.aggregate(OAuthTransaction, :count) == 0
  end

  test "uses the transaction foreign key instead of a separate account existence query", %{
    mailbox: mailbox
  } do
    handler_id = "oauth-repo-query-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:manifold, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          send(pid, {:oauth_repo_query, metadata.query})
        end,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _authorization} =
             OAuth.start(
               "microsoft",
               mailbox.id,
               "https://mail.example.test/connectors/microsoft/callback"
             )

    refute Enum.any?(received_repo_queries(), &String.contains?(&1, ~s(FROM "mailboxes")))
  end

  test "rejects a nonexistent account ID without creating a transaction" do
    assert {:error, %{class: :permanent, reason: :invalid_oauth_request, details: %{}}} =
             OAuth.start(
               "gmail",
               Ecto.UUID.generate(),
               "https://mail.example.test/connectors/gmail/callback"
             )

    assert Repo.aggregate(OAuthTransaction, :count) == 0
  end

  test "consumes matching OAuth state exactly once", %{mailbox: mailbox} do
    redirect_uri = "https://mail.example.test/connectors/gmail/callback"
    now = ~U[2026-07-29 01:00:00.000000Z]

    assert {:ok, authorization} =
             OAuth.start("gmail", mailbox.id, redirect_uri, now: now)

    assert {:error, %{reason: :oauth_state_mismatch}} =
             OAuth.consume(
               "microsoft",
               authorization.state,
               redirect_uri,
               now: DateTime.add(now, 30, :second)
             )

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

  defp assert_secret_free_telemetry(measurements, metadata, secret_values) do
    assert Map.keys(measurements) |> Enum.sort() == [:attempt_count, :duration_ms]

    forbidden_fragments =
      ~w(token password authorization_code raw_message) ++
        Enum.map(secret_values, &String.downcase/1)

    telemetry_terms(measurements)
    |> Enum.concat(telemetry_terms(metadata))
    |> Enum.each(fn term ->
      downcased = term |> to_string() |> String.downcase()

      refute Enum.any?(forbidden_fragments, &String.contains?(downcased, &1)),
             "unsafe telemetry term: #{inspect(term)}"
    end)
  end

  defp telemetry_terms(map) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> [key | telemetry_terms(value)] end)
  end

  defp telemetry_terms(list) when is_list(list), do: Enum.flat_map(list, &telemetry_terms/1)

  defp telemetry_terms(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> telemetry_terms()

  defp telemetry_terms(value), do: [value]

  defp authorization_scopes(url) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
    |> Map.fetch!("scope")
    |> String.split()
  end

  defp insert_gmail_authorization!(account_id, granted_scopes) do
    %OAuthAuthorization{}
    |> OAuthAuthorization.changeset(%{
      account_id: account_id,
      provider: "gmail",
      provider_subject_id: "google-sub-#{System.unique_integer([:positive])}",
      email_address: "person@gmail.com",
      granted_scopes: granted_scopes,
      status: "connected",
      key_version: 1,
      access_token_ciphertext: <<1, 2, 3>>,
      refresh_token_ciphertext: <<4, 5, 6>>
    })
    |> Repo.insert!()
  end

  defp insert_legacy_transaction!(provider, mailbox_id, redirect_uri, now) do
    state = "legacy-state-#{System.unique_integer([:positive])}"
    verifier = "legacy-verifier-#{System.unique_integer([:positive])}"

    assert {:ok, ciphertext} =
             Crypto.encrypt(verifier, "oauth:#{provider}:#{mailbox_id}")

    %OAuthTransaction{}
    |> Ecto.Changeset.change(%{
      state_digest: :crypto.hash(:sha256, state),
      provider: provider,
      mailbox_id: mailbox_id,
      purpose: "receive",
      required_scopes: [],
      pkce_verifier_ciphertext: ciphertext,
      redirect_uri: redirect_uri,
      expires_at: DateTime.add(now, 600, :second)
    })
    |> Repo.insert!()

    {state, verifier}
  end

  defp received_repo_queries(queries \\ []) do
    receive do
      {:oauth_repo_query, query} -> received_repo_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end

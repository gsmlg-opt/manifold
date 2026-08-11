defmodule Manifold.Connectors.OAuth do
  @moduledoc """
  One-time OAuth authorization transactions with PKCE.
  """

  import Ecto.Query

  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.GmailScopes
  alias Manifold.Connectors.Schema.{OAuthAuthorization, OAuthTransaction}
  alias Manifold.Core.Error
  alias Manifold.Repo

  @providers ~w(gmail microsoft)
  @default_ttl_seconds 600
  @mailbox_foreign_key "connector_oauth_transactions_mailbox_id_fkey"

  @type purpose :: :receive | :send
  @type purpose_input :: purpose() | String.t()
  @type start_option ::
          {:purpose, purpose_input()} | {:now, DateTime.t()} | {:ttl_seconds, pos_integer()}
  @type start_options :: [start_option()]

  defmodule Authorization do
    @moduledoc false
    @enforce_keys [:url, :state]
    defstruct @enforce_keys

    @type t :: %__MODULE__{url: String.t(), state: String.t()}
  end

  defmodule Consumed do
    @moduledoc false
    @enforce_keys [:provider, :mailbox_id, :redirect_uri, :pkce_verifier]
    defstruct @enforce_keys ++ [purpose: :receive, required_scopes: []]

    @type t :: %__MODULE__{
            provider: String.t(),
            mailbox_id: Ecto.UUID.t(),
            purpose: :receive | :send,
            required_scopes: [String.t()],
            redirect_uri: String.t(),
            pkce_verifier: String.t()
          }
  end

  @doc """
  Starts an OAuth authorization and snapshots its required provider scopes.

  The string purpose values `"receive"` and `"send"` are accepted for compatibility.

  OAuth completion in Task 3 must merge and revalidate granted scopes while holding the
  shared authorization lock; this start-time snapshot is not a concurrency guarantee.
  """
  @spec start(String.t(), Ecto.UUID.t(), String.t(), start_options()) ::
          {:ok, Authorization.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def start(provider, mailbox_id, redirect_uri, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    with {:ok, config} <- provider_config(provider),
         {:ok, purpose} <- normalize_purpose(Keyword.get(opts, :purpose, :receive)),
         {:ok, purpose_scopes} <- required_scopes(provider, purpose),
         :ok <- validate_redirect_uri(redirect_uri),
         true <- is_integer(ttl_seconds) and ttl_seconds > 0,
         {:ok, mailbox_id} <- validate_mailbox_id(mailbox_id),
         required_scopes <- expanded_required_scopes(provider, mailbox_id, purpose_scopes),
         state = random_url_token(),
         verifier = random_url_token(),
         {:ok, encrypted_verifier} <-
           Crypto.encrypt(verifier, verifier_context(provider, mailbox_id)) do
      attrs = %{
        state_digest: state_digest(state),
        provider: provider,
        mailbox_id: mailbox_id,
        purpose: Atom.to_string(purpose),
        required_scopes: required_scopes,
        pkce_verifier_ciphertext: encrypted_verifier,
        redirect_uri: redirect_uri,
        expires_at: DateTime.add(now, ttl_seconds, :second)
      }

      case insert_transaction(attrs) do
        {:ok, _transaction} ->
          {:ok,
           %Authorization{
             url:
               authorization_url(
                 provider,
                 config,
                 redirect_uri,
                 state,
                 verifier,
                 required_scopes
               ),
             state: state
           }}

        {:error, changeset} ->
          {:error, changeset}
      end
    else
      false ->
        {:error,
         Error.new(:permanent, :invalid_oauth_ttl, "OAuth state lifetime must be positive")}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, Error.new(:temporary, :database_unavailable, "OAuth database is unavailable")}
  end

  @spec consume(String.t(), String.t(), String.t(), Keyword.t()) ::
          {:ok, Consumed.t()} | {:error, Error.t()}
  def consume(provider, state, redirect_uri, opts \\ [])
      when is_binary(state) and is_binary(redirect_uri) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.transaction(fn ->
      transaction =
        OAuthTransaction
        |> where([transaction], transaction.state_digest == ^state_digest(state))
        |> lock("FOR UPDATE")
        |> Repo.one()

      consume_transaction(transaction, provider, redirect_uri, now)
    end)
    |> case do
      {:ok, {:ok, %Consumed{} = consumed}} -> {:ok, consumed}
      {:ok, {:error, %Error{} = error}} -> {:error, error}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, database_error(reason)}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, database_error(:unavailable)}
  end

  defp consume_transaction(nil, _provider, _redirect_uri, _now) do
    {:error, oauth_error(:oauth_state_mismatch, "OAuth state does not match")}
  end

  defp consume_transaction(
         %OAuthTransaction{consumed_at: consumed_at},
         _provider,
         _redirect,
         _now
       )
       when not is_nil(consumed_at) do
    {:error, oauth_error(:oauth_state_replayed, "OAuth state was already consumed")}
  end

  defp consume_transaction(transaction, provider, redirect_uri, now) do
    cond do
      provider not in @providers or transaction.provider != provider or
          transaction.redirect_uri != redirect_uri ->
        {:error, oauth_error(:oauth_state_mismatch, "OAuth state does not match")}

      DateTime.compare(transaction.expires_at, now) != :gt ->
        transaction
        |> Ecto.Changeset.change(consumed_at: now)
        |> Repo.update!()

        {:error, oauth_error(:oauth_state_expired, "OAuth state expired")}

      true ->
        with {:ok, purpose} <- persisted_purpose(transaction.purpose),
             {:ok, consumed_scopes} <- consumed_required_scopes(transaction),
             {:ok, verifier} <-
               Crypto.decrypt(
                 transaction.pkce_verifier_ciphertext,
                 verifier_context(transaction.provider, transaction.mailbox_id)
               ) do
          transaction
          |> Ecto.Changeset.change(consumed_at: now)
          |> Repo.update!()

          {:ok,
           %Consumed{
             provider: transaction.provider,
             mailbox_id: transaction.mailbox_id,
             purpose: purpose,
             required_scopes: consumed_scopes,
             redirect_uri: transaction.redirect_uri,
             pkce_verifier: verifier
           }}
        end
    end
  end

  defp authorization_url(provider, config, redirect_uri, state, verifier, required_scopes) do
    query = [
      client_id: Keyword.fetch!(config, :client_id),
      redirect_uri: redirect_uri,
      response_type: "code",
      scope:
        Enum.join(
          Enum.uniq(identity_scopes(provider) ++ normalize_scopes(required_scopes)),
          " "
        ),
      state: state,
      code_challenge: pkce_challenge(verifier),
      code_challenge_method: "S256"
    ]

    query =
      case provider do
        "gmail" ->
          query ++ [access_type: "offline", include_granted_scopes: "true", prompt: "consent"]

        "microsoft" ->
          query ++ [response_mode: "query"]
      end

    Keyword.fetch!(config, :authorization_url) <> "?" <> URI.encode_query(query)
  end

  defp required_scopes("gmail", :receive), do: {:ok, [GmailScopes.read()]}
  defp required_scopes("gmail", :send), do: {:ok, [GmailScopes.send()]}
  defp required_scopes("microsoft", :receive), do: {:ok, ["Mail.Read", "offline_access"]}

  defp required_scopes("microsoft", :send) do
    {:error,
     oauth_error(:unsupported_oauth_purpose, "OAuth purpose is not supported by provider")}
  end

  defp identity_scopes("gmail"), do: ["openid", "email"]
  defp identity_scopes("microsoft"), do: ["openid", "profile", "User.Read"]

  defp expanded_required_scopes("gmail", mailbox_id, purpose_scopes) do
    existing_scopes =
      OAuthAuthorization
      |> where(
        [authorization],
        authorization.account_id == ^mailbox_id and authorization.provider == "gmail"
      )
      |> select([authorization], authorization.granted_scopes)
      |> Repo.one()
      |> List.wrap()
      |> List.flatten()
      |> Enum.filter(&(&1 in [GmailScopes.read(), GmailScopes.send()]))

    normalize_scopes(existing_scopes ++ purpose_scopes)
  end

  defp expanded_required_scopes("microsoft", _mailbox_id, purpose_scopes),
    do: normalize_scopes(purpose_scopes)

  defp normalize_purpose(purpose) when purpose in [:receive, "receive"], do: {:ok, :receive}
  defp normalize_purpose(purpose) when purpose in [:send, "send"], do: {:ok, :send}

  defp normalize_purpose(_purpose) do
    {:error, oauth_error(:invalid_oauth_purpose, "OAuth purpose is invalid")}
  end

  defp persisted_purpose("receive"), do: {:ok, :receive}
  defp persisted_purpose("send"), do: {:ok, :send}

  defp persisted_purpose(_purpose) do
    {:error, oauth_error(:oauth_state_mismatch, "OAuth state does not match")}
  end

  defp consumed_required_scopes(%OAuthTransaction{
         provider: provider,
         required_scopes: scopes
       })
       when scopes in [nil, []] do
    required_scopes(provider, :receive)
  end

  defp consumed_required_scopes(%OAuthTransaction{required_scopes: scopes}), do: {:ok, scopes}

  defp normalize_scopes(scopes), do: scopes |> Enum.uniq() |> Enum.sort()

  defp provider_config(provider) when provider in @providers do
    providers = Application.get_env(:manifold_connectors, :providers, [])

    case Keyword.get(providers, String.to_existing_atom(provider)) do
      config when is_list(config) ->
        if Keyword.has_key?(config, :client_id) and
             Keyword.has_key?(config, :authorization_url) do
          {:ok, config}
        else
          provider_not_configured(provider)
        end

      _missing ->
        provider_not_configured(provider)
    end
  end

  defp provider_config(_provider) do
    {:error, oauth_error(:unsupported_provider, "OAuth provider is not supported")}
  end

  defp provider_not_configured(provider) do
    {:error,
     Error.new(
       :permanent,
       :provider_not_configured,
       "OAuth provider is not configured",
       %{provider: provider}
     )}
  end

  defp validate_redirect_uri(uri) do
    parsed = URI.parse(uri)

    if parsed.scheme in ["https", "http"] and is_binary(parsed.host) and parsed.host != "" and
         is_nil(parsed.fragment) do
      :ok
    else
      {:error, oauth_error(:invalid_redirect_uri, "OAuth redirect URI is invalid")}
    end
  end

  defp validate_mailbox_id(mailbox_id) do
    case Ecto.UUID.cast(mailbox_id) do
      {:ok, mailbox_id} -> {:ok, mailbox_id}
      :error -> {:error, oauth_error(:invalid_oauth_request, "OAuth request is invalid")}
    end
  end

  defp insert_transaction(attrs) do
    OAuthTransaction.changeset(%OAuthTransaction{}, attrs)
    |> Repo.insert()
  rescue
    error in Ecto.ConstraintError ->
      if error.type == :foreign_key and error.constraint == @mailbox_foreign_key do
        {:error, oauth_error(:invalid_oauth_request, "OAuth request is invalid")}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp random_url_token,
    do: 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp state_digest(state), do: :crypto.hash(:sha256, state)

  defp pkce_challenge(verifier) do
    verifier
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  defp verifier_context(provider, mailbox_id), do: "oauth:" <> provider <> ":" <> mailbox_id

  defp oauth_error(reason, message), do: Error.new(:permanent, reason, message)

  defp database_error(reason) do
    Error.new(:temporary, :database_unavailable, "OAuth database operation failed", %{
      reason: inspect(reason)
    })
  end
end

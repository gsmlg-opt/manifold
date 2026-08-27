defmodule Manifold.Connectors.OAuth do
  @moduledoc """
  One-time OAuth authorization transactions with PKCE.
  """

  import Ecto.Query

  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.OAuthScopes
  alias Manifold.Connectors.ProviderConfig
  alias Manifold.Connectors.Schema.{OAuthAuthorization, OAuthTransaction}
  alias Manifold.Core.Error
  alias Manifold.Repo

  @providers ~w(gmail microsoft)
  @default_ttl_seconds 600
  @mailbox_foreign_key "connector_oauth_transactions_mailbox_id_fkey"
  @telemetry_forbidden_fragments ~w(token password authorization_code raw_message)
  @telemetry_code_pattern ~r/\A[a-z0-9_.:-]{1,128}\z/

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
    defstruct @enforce_keys ++
                [
                  purpose: :receive,
                  required_scopes: [],
                  oauth_provider_setting_id: nil,
                  oauth_provider_setting_lock_version: nil
                ]

    @type t :: %__MODULE__{
            provider: String.t(),
            mailbox_id: Ecto.UUID.t(),
            purpose: :receive | :send,
            required_scopes: [String.t()],
            redirect_uri: String.t(),
            pkce_verifier: String.t(),
            oauth_provider_setting_id: Ecto.UUID.t() | nil,
            oauth_provider_setting_lock_version: pos_integer() | nil
          }
  end

  @doc """
  Starts an OAuth authorization and snapshots its required provider scopes.

  The string purpose values `"receive"` and `"send"` are accepted for compatibility.
  """
  @spec start(String.t(), Ecto.UUID.t(), String.t(), start_options()) ::
          {:ok, Authorization.t()} | {:error, Error.t() | Ecto.Changeset.t()}
  def start(provider, mailbox_id, redirect_uri, opts \\ []) do
    start = System.monotonic_time()
    result = do_start(provider, mailbox_id, redirect_uri, opts)
    emit_start_stop(provider, mailbox_id, result, start)
    result
  end

  defp do_start(provider, mailbox_id, redirect_uri, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    ttl_seconds = Keyword.get(opts, :ttl_seconds, @default_ttl_seconds)

    with {:ok, %ProviderConfig.Resolved{} = resolved} <- ProviderConfig.fetch(provider),
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
        oauth_provider_setting_id: resolved.setting_id,
        oauth_provider_setting_lock_version: resolved.setting_lock_version,
        expires_at: DateTime.add(now, ttl_seconds, :second)
      }

      case insert_transaction(attrs) do
        {:ok, _transaction} ->
          {:ok,
           %Authorization{
             url:
               authorization_url(
                 provider,
                 resolved.config,
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

  defp emit_start_stop(provider, mailbox_id, result, start) do
    {outcome, error_code} =
      case result do
        {:ok, %Authorization{}} -> {:started, nil}
        {:error, reason} -> {:error, telemetry_error_code(reason)}
      end

    safe_provider = if provider in @providers, do: provider, else: "unsupported"

    metadata = %{
      account_id: internal_id(mailbox_id),
      provider: safe_provider,
      method_kind: safe_provider,
      outcome: outcome
    }

    metadata = if error_code, do: Map.put(metadata, :error_code, error_code), else: metadata

    :telemetry.execute(
      [:manifold, :connectors, :oauth, :start, :stop],
      %{
        duration_ms:
          System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond),
        attempt_count: 1
      },
      metadata
    )
  end

  defp internal_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, internal_id} -> internal_id
      :error -> nil
    end
  end

  defp telemetry_error_code(%Error{reason: reason}), do: telemetry_error_code(reason)
  defp telemetry_error_code(%Ecto.Changeset{}), do: :invalid_oauth_request

  defp telemetry_error_code(code) when is_atom(code) do
    if safe_telemetry_code?(Atom.to_string(code)), do: code, else: :oauth_start_failed
  end

  defp telemetry_error_code(code) when is_binary(code) do
    if safe_telemetry_code?(code), do: code, else: "oauth_start_failed"
  end

  defp telemetry_error_code(_reason), do: :oauth_start_failed

  defp safe_telemetry_code?(code) do
    downcased = String.downcase(code)

    Regex.match?(@telemetry_code_pattern, downcased) and
      not Enum.any?(@telemetry_forbidden_fragments, &String.contains?(downcased, &1))
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
        with :ok <- validate_transaction_generation(transaction),
             {:ok, purpose} <- persisted_purpose(transaction.purpose),
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
             pkce_verifier: verifier,
             oauth_provider_setting_id: transaction.oauth_provider_setting_id,
             oauth_provider_setting_lock_version: transaction.oauth_provider_setting_lock_version
           }}
        else
          {:error, %Error{reason: :provider_configuration_changed} = error} ->
            consume_invalidated_transaction(transaction, now, error)

          {:error, %Error{} = error} ->
            {:error, error}
        end
    end
  end

  defp validate_transaction_generation(%OAuthTransaction{
         provider: provider,
         oauth_provider_setting_id: setting_id,
         oauth_provider_setting_lock_version: setting_lock_version
       })
       when provider in @providers and is_binary(setting_id) and is_integer(setting_lock_version) do
    case ProviderConfig.fetch(provider) do
      {:ok,
       %ProviderConfig.Resolved{
         setting_id: ^setting_id,
         setting_lock_version: ^setting_lock_version
       }} ->
        :ok

      {:ok, %ProviderConfig.Resolved{}} ->
        provider_configuration_changed()

      {:error, %Error{reason: reason}}
      when reason in [:provider_not_configured, :provider_configuration_error] ->
        provider_configuration_changed()

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_transaction_generation(%OAuthTransaction{provider: provider})
       when provider in @providers,
       do: provider_configuration_changed()

  defp validate_transaction_generation(%OAuthTransaction{}), do: :ok

  defp consume_invalidated_transaction(
         %OAuthTransaction{
           provider: provider,
           oauth_provider_setting_id: nil,
           oauth_provider_setting_lock_version: nil
         } = transaction,
         _now,
         error
       )
       when provider in @providers do
    Repo.delete!(transaction)
    {:error, error}
  end

  defp consume_invalidated_transaction(transaction, now, error) do
    transaction
    |> Ecto.Changeset.change(consumed_at: now)
    |> Repo.update!()

    {:error, error}
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

  defp required_scopes(provider, purpose) do
    case OAuthScopes.purpose(provider, purpose) do
      {:ok, scopes} ->
        {:ok, scopes}

      :error ->
        {:error,
         oauth_error(
           :unsupported_oauth_purpose,
           "OAuth purpose is not supported by provider"
         )}
    end
  end

  defp identity_scopes(provider), do: OAuthScopes.identity(provider)

  defp expanded_required_scopes(provider, mailbox_id, purpose_scopes) do
    existing_scopes =
      OAuthAuthorization
      |> where(
        [authorization],
        authorization.account_id == ^mailbox_id and authorization.provider == ^provider
      )
      |> select([authorization], authorization.granted_scopes)
      |> Repo.one()
      |> List.wrap()
      |> List.flatten()
      |> Enum.filter(&OAuthScopes.approved?(provider, &1))

    normalize_scopes(existing_scopes ++ purpose_scopes)
  end

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

  defp provider_configuration_changed do
    {:error,
     Error.new(
       :permanent,
       :provider_configuration_changed,
       "OAuth provider configuration changed"
     )}
  end

  defp database_error(reason) do
    Error.new(:temporary, :database_unavailable, "OAuth database operation failed", %{
      reason: inspect(reason)
    })
  end
end

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
  @callback_response_keys ~w(code state error scope authuser prompt hd error_description error_uri)

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
         redirect_uri = resolved.callback_url || redirect_uri,
         :ok <- browser_flow(resolved.config),
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

  defp browser_flow(config) do
    if Keyword.get(config, :auth_flow) == "device_code" do
      {:error,
       Error.new(
         :permanent,
         :device_authorization_required,
         "Use Microsoft device-code login for this configuration"
       )}
    else
      :ok
    end
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

  @doc """
  Consumes a pasted Google callback URL for the account's current authorization attempt.
  The URL is parsed locally and is never requested over the network.
  """
  @spec consume_callback_url(String.t(), String.t(), String.t(), Ecto.UUID.t(), Keyword.t()) ::
          {:ok, String.t(), Consumed.t()} | {:error, Error.t()}
  def consume_callback_url(provider, response_url, expected_state, account_id, opts \\ [])

  def consume_callback_url("gmail", response_url, expected_state, account_id, opts)
      when is_binary(response_url) and is_binary(expected_state) and expected_state != "" do
    with {:ok, uri, params} <- parse_callback_url(response_url),
         {:ok, code} <- callback_code(params, expected_state),
         {:ok, account_id} <- validate_mailbox_id(account_id) do
      now = Keyword.get(opts, :now, DateTime.utc_now())

      Repo.transaction(fn ->
        transaction =
          OAuthTransaction
          |> where([transaction], transaction.state_digest == ^state_digest(expected_state))
          |> lock("FOR UPDATE")
          |> Repo.one()

        with :ok <- validate_pasted_callback(transaction, uri, params, account_id, opts),
             {:ok, consumed} <-
               consume_transaction(transaction, "gmail", transaction.redirect_uri, now) do
          {:ok, code, consumed}
        end
      end)
      |> case do
        {:ok, {:ok, code, %Consumed{} = consumed}} -> {:ok, code, consumed}
        {:ok, {:error, %Error{} = error}} -> {:error, error}
        {:error, %Error{} = error} -> {:error, error}
        {:error, _reason} -> {:error, database_error(:unavailable)}
      end
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  def consume_callback_url("gmail", _url, _state, _account_id, _opts),
    do: invalid_callback_url()

  def consume_callback_url(_provider, _url, _state, _account_id, _opts),
    do: {:error, oauth_error(:unsupported_provider, "OAuth provider is not supported")}

  defp parse_callback_url(url) do
    with {:ok, %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} = uri} <-
           URI.new(String.trim(url)),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "",
         false <- Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, uri.query || "") do
      {:ok, uri, URI.query_decoder(uri.query || "") |> Enum.to_list()}
    else
      _invalid -> invalid_callback_url()
    end
  rescue
    ArgumentError -> invalid_callback_url()
  end

  defp callback_code(params, expected_state) do
    grouped = Enum.group_by(params, &elem(&1, 0), &elem(&1, 1))

    cond do
      Enum.any?(~w(code state error), &(length(Map.get(grouped, &1, [])) > 1)) ->
        invalid_callback_url()

      Map.get(grouped, "state") != [expected_state] ->
        invalid_callback_url()

      Map.has_key?(grouped, "error") ->
        {:error, oauth_error(:oauth_authorization_denied, "OAuth authorization was denied")}

      true ->
        case {Map.get(grouped, "state"), Map.get(grouped, "code")} do
          {[^expected_state], [code]} when is_binary(code) ->
            if String.trim(code) == "", do: invalid_callback_url(), else: {:ok, code}

          _invalid ->
            invalid_callback_url()
        end
    end
  end

  defp validate_pasted_callback(nil, _uri, _params, _account_id, _opts),
    do: callback_mismatch()

  defp validate_pasted_callback(transaction, uri, params, account_id, opts) do
    with true <- transaction.provider == "gmail" and transaction.mailbox_id == account_id,
         {:ok, registered, static_params} <- parse_callback_url(transaction.redirect_uri),
         true <- callback_target(uri) == callback_target(registered),
         true <- callback_static_params(params, static_params) == Enum.sort(static_params),
         :ok <- validate_callback_purpose(transaction, opts) do
      :ok
    else
      _mismatch -> callback_mismatch()
    end
  end

  defp callback_target(uri), do: {uri.scheme, uri.host, uri.port, uri.path}

  defp callback_static_params(params, registered) do
    static_keys = Enum.map(registered, &elem(&1, 0))

    params
    |> Enum.reject(fn {key, _value} ->
      key in @callback_response_keys and key not in static_keys
    end)
    |> Enum.sort()
  end

  defp validate_callback_purpose(transaction, opts) do
    case Keyword.fetch(opts, :purpose) do
      :error ->
        :ok

      {:ok, purpose} ->
        with {:ok, expected} <- normalize_purpose(purpose),
             {:ok, ^expected} <- persisted_purpose(transaction.purpose),
             do: :ok
    end
  end

  defp invalid_callback_url,
    do: {:error, oauth_error(:invalid_oauth_callback, "OAuth callback URL is invalid")}

  defp callback_mismatch,
    do: {:error, oauth_error(:oauth_state_mismatch, "OAuth state does not match")}

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
         provider: ^provider,
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

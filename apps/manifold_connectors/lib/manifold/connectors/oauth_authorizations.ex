defmodule Manifold.Connectors.OAuthAuthorizations do
  @moduledoc false

  import Ecto.Query
  import Bitwise, only: [bor: 2, bxor: 2]

  alias Manifold.Accounts
  alias Manifold.Accounts.Schema.Account
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.Jobs.SyncAccount
  alias Manifold.Connectors.MicrosoftScopes
  alias Manifold.Connectors.OAuth.Consumed
  alias Manifold.Connectors.OAuthScopes
  alias Manifold.Connectors.Provider.{Identity, SyncCursor, Token}
  alias Manifold.Connectors.Provider.Error, as: ProviderError

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    Credential,
    OAuthAuthorization,
    ReceiveMethod,
    SendCredential,
    SendMethod,
    SmtpSettings
  }

  alias Manifold.Connectors.Schema.SyncCursor, as: StoredCursor
  alias Manifold.Core.Address
  alias Manifold.Core.Error, as: CoreError
  alias Manifold.Repo

  @providers ~w(gmail microsoft)
  @refresh_skew_seconds 60
  @telemetry_forbidden_fragments ~w(token password authorization_code raw_message)
  @telemetry_code_pattern ~r/\A[a-z0-9_.:-]{1,128}\z/

  @spec complete(String.t(), String.t(), Consumed.t(), module(), keyword(), keyword()) ::
          {:ok, ReceiveMethod.t() | SendMethod.t()}
          | {:error, CoreError.t() | Ecto.Changeset.t()}
  def complete(provider, code, consumed, adapter, config, opts \\ [])

  def complete(provider, code, %Consumed{provider: provider} = consumed, adapter, config, opts)
      when provider in @providers do
    start = System.monotonic_time()
    now = Keyword.get(opts, :now, DateTime.utc_now())

    provider_opts =
      opts
      |> Keyword.get(:provider_opts, [])
      |> Keyword.put(:required_scopes, consumed.required_scopes)

    case capture_complete(fn ->
           with {:ok, purpose} <- normalize_purpose(consumed.purpose),
                {:ok, %Token{} = token} <-
                  adapter.exchange_code(
                    code,
                    consumed.pkce_verifier,
                    consumed.redirect_uri,
                    config,
                    provider_opts
                  ),
                {:ok, %Identity{} = identity} <-
                  adapter.identity(token.access_token, config, provider_opts),
                {:ok, provider_address} <- Address.parse(identity.email_address),
                {:ok, cursors} <- initial_cursors(purpose, adapter, token, config, provider_opts),
                :ok <- validate_cursors(purpose, cursors) do
             persist(provider, consumed, purpose, token, identity, provider_address, cursors, now)
           else
             {:error, %ProviderError{} = error} -> {:error, provider_error(error)}
             {:error, %CoreError{} = error} -> {:error, error}
           end
         end) do
      {:return, result} ->
        emit_oauth_complete(consumed, result, start)
        public_complete_result(result)

      {:exception, exception, stacktrace} ->
        emit_oauth_complete(consumed, unexpected_complete_result(), start)
        reraise(exception, stacktrace)
    end
  end

  def complete(_provider, _code, %Consumed{}, _adapter, _config, _opts) do
    {:error, CoreError.new(:permanent, :oauth_provider_mismatch, "OAuth provider does not match")}
  end

  defp capture_complete(fun) do
    {:return, fun.()}
  rescue
    DBConnection.ConnectionError ->
      {:return, {:error, database_error()}}

    error in Postgrex.Error ->
      case error do
        %Postgrex.Error{postgres: %{code: code}}
        when code in [:deadlock_detected, :serialization_failure] ->
          {:return, {:error, database_error()}}

        _unexpected ->
          {:exception, error, __STACKTRACE__}
      end

    exception ->
      {:exception, exception, __STACKTRACE__}
  end

  defp unexpected_complete_result do
    {:error,
     CoreError.new(:temporary, :unexpected_exception, "OAuth completion failed unexpectedly")}
  end

  @spec checkout_access_token(Ecto.UUID.t(), module(), keyword(), keyword()) ::
          {:ok, term()}
          | {:error, CoreError.t() | ProviderError.t() | Ecto.Changeset.t()}
  def checkout_access_token(authorization_id, adapter, config, opts \\ []) do
    required_scope = Keyword.get(opts, :required_scope)

    expected_authorization_lock_version =
      Keyword.get(opts, :expected_authorization_lock_version)

    now = Keyword.get(opts, :now, DateTime.utc_now())
    provider_opts = Keyword.get(opts, :provider_opts, [])
    continuation = Keyword.get(opts, :access_token_continuation, &default_continuation/1)

    Repo.transaction(fn ->
      with {:ok, authorization} <- lock_authorization(authorization_id),
           :ok <-
             validate_expected_authorization_lock_version(
               authorization,
               expected_authorization_lock_version
             ),
           :ok <- validate_required_scope(authorization.provider, required_scope),
           :ok <- validate_checkout_authorization(authorization, required_scope) do
        authorization
        |> checkout_locked_access_token(
          required_scope,
          adapter,
          config,
          now,
          provider_opts
        )
        |> continue_with_access_token(continuation)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:reconnect, %ProviderError{} = error}} -> {:error, error}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, database_error()}

    error in Postgrex.Error ->
      normalize_transaction_error(error, __STACKTRACE__)
  end

  @spec add_authorized_method(
          String.t(),
          Ecto.UUID.t(),
          :receive | :send,
          module(),
          keyword(),
          keyword()
        ) ::
          {:ok, ReceiveMethod.t() | SendMethod.t()}
          | {:error, CoreError.t() | ProviderError.t() | Ecto.Changeset.t()}
  def add_authorized_method(provider, account_id, purpose, adapter, config, opts \\ [])

  def add_authorized_method(provider, account_id, purpose, adapter, config, opts)
      when provider in @providers and purpose in [:receive, :send] do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    provider_opts = Keyword.get(opts, :provider_opts, [])

    after_authorized_method_snapshot =
      Keyword.get(opts, :after_authorized_method_snapshot)

    with {:ok, required_scope} <- method_scope(provider, purpose) do
      case purpose do
        :receive ->
          add_authorized_receive_method(
            provider,
            account_id,
            required_scope,
            adapter,
            config,
            now,
            provider_opts,
            after_authorized_method_snapshot
          )

        :send ->
          add_authorized_send_method(provider, account_id, required_scope, now)
      end
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error()}
    error in Postgrex.Error -> normalize_transaction_error(error, __STACKTRACE__)
  end

  def add_authorized_method(_provider, _account_id, _purpose, _adapter, _config, _opts) do
    {:error,
     CoreError.new(
       :permanent,
       :unsupported_oauth_purpose,
       "OAuth purpose is not supported by provider"
     )}
  end

  defp add_authorized_send_method(provider, account_id, required_scope, now) do
    authorized_method_transaction(fn ->
      with {:ok, account, account_address} <- lock_account(account_id),
           {:ok, authorization} <- lock_account_authorization(provider, account.id),
           {:ok, authorization_address} <- Address.parse(authorization.email_address),
           :ok <- require_matching_address(account_address, authorization_address),
           :ok <- validate_checkout_authorization(authorization, required_scope),
           {:ok, method} <-
             upsert_method(
               provider,
               :send,
               account.id,
               authorization,
               authorization.provider_subject_id,
               account_address.canonical,
               authorization.granted_scopes,
               now
             ),
           {:ok, _event} <-
             insert_authorization_event(
               authorization.id,
               provider,
               "connected",
               :send,
               now
             ) do
        {:ok, method}
      end
    end)
  end

  defp add_authorized_receive_method(
         provider,
         account_id,
         required_scope,
         adapter,
         config,
         now,
         provider_opts,
         after_authorized_method_snapshot
       ) do
    case authorized_method_snapshot(provider, account_id, required_scope) do
      {:ok, {:unchanged, method}} ->
        {:ok, method}

      {:ok, {:setup, snapshot}} ->
        with :ok <- maybe_after_authorized_method_snapshot(after_authorized_method_snapshot),
             {:ok, checkout} <-
               checkout_authorized_method_access(
                 snapshot,
                 required_scope,
                 adapter,
                 config,
                 now,
                 provider_opts
               ),
             {:ok, cursors} <-
               adapter.initial_cursors(checkout.access_token, config, provider_opts),
             :ok <- validate_cursors(:receive, cursors) do
          persist_authorized_receive_method(snapshot, checkout, cursors, required_scope, now)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorized_method_snapshot(provider, account_id, required_scope) do
    authorized_method_transaction(fn ->
      with {:ok, account, account_address} <- lock_account(account_id),
           {:ok, authorization} <- lock_account_authorization(provider, account.id),
           {:ok, authorization_address} <- Address.parse(authorization.email_address),
           :ok <- require_matching_address(account_address, authorization_address),
           :ok <- validate_checkout_authorization(authorization, required_scope),
           {:ok, lifecycle} <- lock_receive_method_lifecycle(account.id, provider) do
        case active_receive_method_result(
               lifecycle.provider_method,
               authorization,
               account_address,
               required_scope
             ) do
          {:unchanged, method} ->
            {:ok, {:unchanged, method}}

          :setup ->
            {:ok,
             {:setup,
              %{
                account_id: account.id,
                account_address: account_address.canonical,
                authorization_id: authorization.id,
                phase_one_authorization_lock_version: authorization.lock_version,
                provider: authorization.provider,
                provider_subject_id: authorization.provider_subject_id,
                email_address: authorization.email_address,
                provider_receive_method:
                  receive_method_lifecycle_snapshot(lifecycle.provider_method),
                enabled_receive_method: enabled_receive_method_snapshot(lifecycle.enabled_method)
              }}}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end)
  end

  defp checkout_authorized_method_access(
         snapshot,
         required_scope,
         adapter,
         config,
         now,
         provider_opts
       ) do
    continuation = fn access_token ->
      with {:ok, authorization} <- lock_authorization(snapshot.authorization_id),
           true <- same_authorization_binding?(authorization, snapshot) do
        {:ok,
         %{
           access_token: access_token,
           authorization_id: authorization.id,
           authorization_lock_version: authorization.lock_version,
           authorization_status: authorization.status,
           granted_scopes: authorization.granted_scopes
         }}
      else
        false -> {:error, stale_oauth_authorization()}
        {:error, reason} -> {:error, reason}
      end
    end

    checkout_access_token(snapshot.authorization_id, adapter, config,
      required_scope: required_scope,
      expected_authorization_lock_version: snapshot.phase_one_authorization_lock_version,
      now: now,
      provider_opts: provider_opts,
      access_token_continuation: continuation
    )
  end

  defp persist_authorized_receive_method(snapshot, checkout, cursors, required_scope, now) do
    authorized_method_transaction(fn ->
      with {:ok, account, account_address} <- lock_account(snapshot.account_id),
           {:ok, authorization} <- lock_authorization(snapshot.authorization_id),
           :ok <-
             validate_authorized_method_snapshot(
               account_address,
               authorization,
               snapshot,
               checkout,
               required_scope
             ),
           :ok <- lock_receive_setup_cursors(snapshot.provider_receive_method),
           {:ok, lifecycle} <-
             lock_receive_method_lifecycle(
               account.id,
               snapshot.provider,
               receive_method_lifecycle_ids(snapshot)
             ),
           :ok <- validate_receive_method_lifecycle(snapshot, lifecycle),
           {:ok, method} <-
             upsert_method(
               snapshot.provider,
               :receive,
               account.id,
               authorization,
               authorization.provider_subject_id,
               account_address.canonical,
               authorization.granted_scopes,
               now
             ),
           :ok <- persist_receive_state(:receive, method, cursors, now),
           {:ok, _event} <-
             insert_authorization_event(
               authorization.id,
               snapshot.provider,
               "connected",
               :receive,
               now
             ) do
        {:ok, method}
      end
    end)
  end

  defp validate_authorized_method_snapshot(
         account_address,
         authorization,
         snapshot,
         checkout,
         required_scope
       ) do
    with true <- account_address.canonical == snapshot.account_address,
         true <- same_authorization_binding?(authorization, snapshot),
         {:ok, authorization_address} <- Address.parse(authorization.email_address),
         :ok <- require_matching_address(account_address, authorization_address),
         :ok <- validate_checkout_authorization(authorization, required_scope),
         true <- authorization.status == checkout.authorization_status,
         true <- authorization.granted_scopes == checkout.granted_scopes,
         true <- authorization.lock_version == checkout.authorization_lock_version,
         {:ok, true} <-
           expected_access_token_matches?(authorization,
             expected_access_token: checkout.access_token
           ) do
      :ok
    else
      false -> {:error, stale_oauth_authorization()}
      {:ok, false} -> {:error, stale_oauth_authorization()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_authorization_binding?(authorization, snapshot) do
    authorization.id == snapshot.authorization_id and
      authorization.account_id == snapshot.account_id and
      authorization.provider == snapshot.provider and
      authorization.provider_subject_id == snapshot.provider_subject_id and
      authorization.email_address == snapshot.email_address
  end

  defp maybe_after_authorized_method_snapshot(nil), do: :ok

  defp maybe_after_authorized_method_snapshot(hook) when is_function(hook, 0),
    do: hook.()

  defp validate_expected_authorization_lock_version(_authorization, nil), do: :ok

  defp validate_expected_authorization_lock_version(
         %OAuthAuthorization{lock_version: lock_version},
         lock_version
       ),
       do: :ok

  defp validate_expected_authorization_lock_version(_authorization, _expected_lock_version),
    do: {:error, stale_oauth_authorization()}

  defp lock_receive_method_lifecycle(account_id, provider, snapshot_ids \\ []) do
    methods =
      ReceiveMethod
      |> where(
        [method],
        method.account_id == ^account_id and
          (method.kind == ^provider or method.enabled or method.id in ^snapshot_ids)
      )
      |> order_by([method], asc: method.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    with {:ok, provider_method} <- optional_receive_method(methods, &(&1.kind == provider)),
         {:ok, enabled_method} <- optional_receive_method(methods, & &1.enabled) do
      {:ok, %{provider_method: provider_method, enabled_method: enabled_method}}
    end
  end

  defp optional_receive_method(methods, predicate) do
    case Enum.filter(methods, predicate) do
      [] -> {:ok, nil}
      [method] -> {:ok, method}
      _multiple -> {:error, stale_oauth_authorization()}
    end
  end

  defp healthy_active_receive_method?(%ReceiveMethod{
         status: status,
         enabled: true,
         sync_enabled: true
       })
       when status in ["connected", "syncing"],
       do: true

  defp healthy_active_receive_method?(_method), do: false

  defp active_receive_method_result(method, authorization, account_address, required_scope) do
    cond do
      not healthy_active_receive_method?(method) ->
        :setup

      authorized_receive_method_binding?(
        method,
        authorization,
        account_address,
        required_scope
      ) ->
        {:unchanged, method}

      true ->
        {:error, stale_oauth_authorization()}
    end
  end

  defp authorized_receive_method_binding?(
         method,
         authorization,
         account_address,
         required_scope
       ) do
    method_scopes = MapSet.new(method.granted_scopes)
    authorization_scopes = MapSet.new(authorization.granted_scopes)

    with true <- method.oauth_authorization_id == authorization.id,
         true <- method.kind == authorization.provider,
         true <- method.provider_account_id == authorization.provider_subject_id,
         true <- MapSet.member?(method_scopes, required_scope),
         true <- MapSet.subset?(method_scopes, authorization_scopes),
         {:ok, method_address} <- Address.parse(method.email_address),
         :ok <- require_matching_address(account_address, method_address) do
      true
    else
      _mismatch -> false
    end
  end

  defp receive_method_lifecycle_snapshot(nil), do: :absent

  defp receive_method_lifecycle_snapshot(%ReceiveMethod{} = method) do
    {:present,
     Map.take(method, [
       :id,
       :kind,
       :status,
       :enabled,
       :sync_enabled,
       :oauth_authorization_id,
       :lock_version
     ])}
  end

  defp enabled_receive_method_snapshot(nil), do: :absent

  defp enabled_receive_method_snapshot(%ReceiveMethod{} = method) do
    {:present, Map.take(method, [:id, :kind, :lock_version])}
  end

  defp receive_method_lifecycle_ids(snapshot) do
    [snapshot.provider_receive_method, snapshot.enabled_receive_method]
    |> Enum.flat_map(fn
      {:present, %{id: id}} -> [id]
      :absent -> []
    end)
    |> Enum.uniq()
  end

  defp lock_receive_setup_cursors(:absent), do: :ok

  defp lock_receive_setup_cursors({:present, %{id: method_id}}),
    do: lock_receive_method_cursors(method_id)

  defp lock_receive_method_cursors(method_id) do
    try do
      StoredCursor
      |> where([cursor], cursor.external_account_id == ^method_id)
      |> order_by([cursor], asc: cursor.id)
      |> lock("FOR UPDATE NOWAIT")
      |> Repo.all()

      :ok
    rescue
      error in Postgrex.Error ->
        case error do
          %Postgrex.Error{postgres: %{code: code}}
          when code in [:lock_not_available, "55P03"] ->
            {:error, oauth_lifecycle_busy()}

          _unexpected ->
            reraise(error, __STACKTRACE__)
        end
    end
  end

  defp validate_receive_method_lifecycle(snapshot, lifecycle) do
    provider_method = receive_method_lifecycle_snapshot(lifecycle.provider_method)
    enabled_method = enabled_receive_method_snapshot(lifecycle.enabled_method)

    if provider_method == snapshot.provider_receive_method and
         enabled_method == snapshot.enabled_receive_method do
      :ok
    else
      {:error, stale_oauth_authorization()}
    end
  end

  defp stale_oauth_authorization do
    CoreError.new(
      :permanent,
      :stale_oauth_authorization,
      "OAuth authorization or receive-method lifecycle changed before setup completed"
    )
  end

  defp oauth_lifecycle_busy do
    CoreError.new(
      :temporary,
      :oauth_lifecycle_busy,
      "OAuth receive lifecycle is changing; retry the operation"
    )
  end

  defp authorized_method_transaction(fun) do
    Repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp checkout_locked_access_token(
         authorization,
         required_scope,
         adapter,
         config,
         now,
         provider_opts
       ) do
    if token_current?(authorization, now) do
      decrypt_access_token(authorization)
    else
      refresh_access_token_locked(
        authorization,
        required_scope,
        adapter,
        config,
        now,
        provider_opts
      )
    end
  end

  defp continue_with_access_token({:ok, access_token}, continuation)
       when is_function(continuation, 1) do
    case continuation.(access_token) do
      {:ok, _result} = ok -> ok
      {:error, _reason} = error -> error
      _invalid -> {:error, invalid_continuation()}
    end
  end

  defp continue_with_access_token({:ok, _access_token}, _invalid_continuation),
    do: {:error, invalid_continuation()}

  defp continue_with_access_token(other, _continuation), do: other

  defp default_continuation(access_token), do: {:ok, access_token}

  defp invalid_continuation do
    CoreError.new(
      :permanent,
      :invalid_access_token_continuation,
      "access token continuation is invalid"
    )
  end

  @spec disconnect_method(:receive, Ecto.UUID.t()) ::
          {:ok, ReceiveMethod.t()}
          | {:error, CoreError.t() | Ecto.Changeset.t()}
  def disconnect_method(:receive, method_id) do
    with {:ok, account_id} <- method_account_id(:receive, method_id) do
      disconnect_method(:receive, account_id, method_id)
    end
  end

  @spec disconnect_method(:receive | :send, Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, ReceiveMethod.t() | SendMethod.t()}
          | {:error, CoreError.t() | Ecto.Changeset.t()}
  def disconnect_method(direction, account_id, method_id)
      when direction in [:receive, :send] and is_binary(account_id) do
    now = DateTime.utc_now()

    with {:ok, authorization_id} <-
           method_authorization_id(direction, account_id, method_id) do
      Repo.transaction(fn ->
        with {:ok, authorization} <- lock_authorization(authorization_id),
             true <- authorization.account_id == account_id,
             {:ok, method} <- lock_method(direction, method_id, authorization),
             {:ok, disconnected} <- disconnect_locked_method(direction, method, now),
             :ok <- delete_method_secrets(direction, method.id),
             {:ok, _authorization} <- maybe_disconnect_authorization(authorization, now),
             {:ok, _event} <-
               insert_authorization_event(
                 authorization.id,
                 authorization.provider,
                 "disconnected",
                 direction,
                 now
               ) do
          disconnected
        else
          false -> Repo.rollback(method_not_found())
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, method} -> {:ok, method}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error()}
    error in Postgrex.Error -> normalize_transaction_error(error, __STACKTRACE__)
  end

  @spec delete_receive_method(Ecto.UUID.t()) ::
          {:ok, ReceiveMethod.t()} | {:error, CoreError.t() | Ecto.Changeset.t()}
  def delete_receive_method(method_id) do
    now = DateTime.utc_now()

    with {:ok, authorization_id} <- method_authorization_id(:receive, method_id) do
      Repo.transaction(fn ->
        with {:ok, authorization} <- lock_authorization(authorization_id),
             :ok <- lock_receive_method_cursors(method_id),
             {:ok, method} <- lock_method(:receive, method_id, authorization),
             :ok <- cancel_receive_jobs(method.id),
             {:ok, deleted} <- Repo.delete(method),
             {:ok, _authorization} <- maybe_disconnect_authorization(authorization, now),
             {:ok, _event} <-
               insert_authorization_event(
                 authorization.id,
                 authorization.provider,
                 "disconnected",
                 :receive,
                 now
               ) do
          deleted
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, method} -> {:ok, method}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error()}
    error in Postgrex.Error -> normalize_transaction_error(error, __STACKTRACE__)
  end

  @spec mark_reconnect_required(Ecto.UUID.t(), ProviderError.t(), keyword()) ::
          {:ok, OAuthAuthorization.t()} | {:error, CoreError.t() | Ecto.Changeset.t()}
  def mark_reconnect_required(authorization_id, %ProviderError{} = provider_error, opts \\ []) do
    case mark_reconnect_required_with_outcome(authorization_id, provider_error, opts) do
      {:ok, _outcome, authorization} -> {:ok, authorization}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_reconnect_required_with_outcome(authorization_id, provider_error, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.transaction(fn ->
      with {:ok, authorization} <- lock_authorization(authorization_id),
           {:ok, outcome, authorization} <-
             maybe_mark_reconnect_required_locked(authorization, provider_error, now, opts) do
        {outcome, authorization}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {outcome, authorization}} -> {:ok, outcome, authorization}
      {:error, reason} -> {:error, reason}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error()}
    error in Postgrex.Error -> normalize_transaction_error(error, __STACKTRACE__)
  end

  @spec mark_send_reconnect_required(Ecto.UUID.t(), String.t(), atom(), Keyword.t()) ::
          {:ok, :marked | :already_marked | :stale | :inactive, OAuthAuthorization.t()}
          | {:error, CoreError.t() | Ecto.Changeset.t()}
  def mark_send_reconnect_required(method_id, expected_access_token, error_code, opts \\ [])
      when is_binary(method_id) and is_binary(expected_access_token) and
             error_code in [:invalid_grant, :insufficient_scope] do
    error = %ProviderError{
      class: :reconnect,
      code: error_code,
      message: "OAuth authorization must be reconnected"
    }

    with {:ok, authorization_id} <- method_authorization_id(:send, method_id) do
      opts = Keyword.put(opts, :expected_access_token, expected_access_token)
      mark_reconnect_required_with_outcome(authorization_id, error, opts)
    end
  end

  defp validate_required_scope(provider, scope) do
    if OAuthScopes.approved?(provider, scope), do: :ok, else: insufficient_scope(provider)
  end

  defp validate_checkout_authorization(
         %OAuthAuthorization{provider: provider, status: "connected"} = authorization,
         required_scope
       )
       when provider in @providers do
    if required_scope in authorization.granted_scopes do
      :ok
    else
      insufficient_scope(provider)
    end
  end

  defp validate_checkout_authorization(
         %OAuthAuthorization{provider: provider, status: "reconnect_required"},
         _required_scope
       )
       when provider in @providers do
    {:error,
     CoreError.new(
       :permanent,
       :reauthorization_required,
       reconnect_message(provider)
     )}
  end

  defp validate_checkout_authorization(
         %OAuthAuthorization{provider: provider, status: "disconnected"},
         _required_scope
       )
       when provider in @providers do
    {:error, CoreError.new(:permanent, :account_disconnected, "authorization is disconnected")}
  end

  defp validate_checkout_authorization(_authorization, _required_scope) do
    {:error,
     CoreError.new(
       :permanent,
       :invalid_oauth_authorization,
       "authorization is not a supported OAuth authorization"
     )}
  end

  defp token_current?(authorization, now) do
    is_binary(authorization.access_token_ciphertext) and
      match?(%DateTime{}, authorization.token_expires_at) and
      DateTime.compare(
        authorization.token_expires_at,
        DateTime.add(now, @refresh_skew_seconds, :second)
      ) == :gt
  end

  defp decrypt_access_token(authorization) do
    Crypto.decrypt(
      authorization.access_token_ciphertext,
      credential_context(authorization.id, :access)
    )
  end

  defp refresh_access_token_locked(
         authorization,
         required_scope,
         adapter,
         config,
         now,
         provider_opts
       ) do
    start = System.monotonic_time()

    result =
      with {:ok, refresh_token} <-
             Crypto.decrypt(
               authorization.refresh_token_ciphertext,
               credential_context(authorization.id, :refresh)
             ) do
        refresh_opts =
          provider_opts
          |> Keyword.put(:required_scopes, authorization.granted_scopes)
          |> Keyword.put(:now, now)

        case adapter.refresh_token(refresh_token, config, refresh_opts) do
          {:ok, %Token{} = token} ->
            persist_refreshed_token_locked(authorization, required_scope, token)

          {:error, %ProviderError{class: :reconnect} = error} ->
            error = sanitize_reconnect_error(error, authorization.provider)

            case mark_reconnect_required_locked(authorization, error, now, []) do
              {:ok, _authorization} -> {:reconnect, error}
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, %ProviderError{} = error} ->
            emit_oauth_refresh(authorization, {:error, error}, start)
            Repo.rollback(error)
        end
      end

    emit_oauth_refresh(authorization, result, start)
    result
  end

  defp sanitize_reconnect_error(error, provider) do
    %{error | message: reconnect_message(provider)}
  end

  defp persist_refreshed_token_locked(authorization, required_scope, token) do
    with {:ok, granted_scopes} <-
           validate_refreshed_scopes(authorization, required_scope, token.scopes),
         {:ok, encrypted_access} <-
           Crypto.encrypt(token.access_token, credential_context(authorization.id, :access)),
         {:ok, encrypted_refresh} <-
           encrypted_refresh(token.refresh_token, authorization, authorization.id),
         {:ok, _authorization} <-
           authorization
           |> OAuthAuthorization.changeset(%{
             access_token_ciphertext: encrypted_access,
             refresh_token_ciphertext: encrypted_refresh,
             token_expires_at: token.expires_at,
             granted_scopes: granted_scopes,
             status: "connected",
             last_error_class: nil,
             last_error_code: nil,
             last_error_message: nil,
             disconnected_at: nil
           })
           |> Repo.update() do
      {:ok, token.access_token}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_refreshed_scopes(authorization, required_scope, token_scopes)
       when is_list(token_scopes) do
    stored = approved_scopes(authorization.provider, authorization.granted_scopes)
    returned = approved_scopes(authorization.provider, token_scopes)
    required = MapSet.put(stored, required_scope)

    if MapSet.subset?(
         access_token_scopes(authorization.provider, required),
         access_token_scopes(authorization.provider, returned)
       ) do
      {:ok, stored |> MapSet.union(returned) |> MapSet.to_list() |> Enum.sort()}
    else
      insufficient_scope(authorization.provider)
    end
  end

  defp validate_refreshed_scopes(authorization, _required_scope, _token_scopes),
    do: insufficient_scope(authorization.provider)

  defp mark_reconnect_required_locked(authorization, provider_error, now, opts) do
    error_attrs = reconnect_error_attrs(authorization.provider, provider_error)

    with {:ok, authorization} <-
           authorization
           |> OAuthAuthorization.changeset(
             Map.merge(error_attrs, %{status: "reconnect_required", disconnected_at: nil})
           )
           |> Repo.update(),
         :ok <-
           disable_dependent_methods(
             authorization.provider,
             authorization.id,
             error_attrs,
             now
           ),
         :ok <- maybe_fault(opts, :after_methods_before_event),
         {:ok, _event} <-
           insert_authorization_event(
             authorization.id,
             authorization.provider,
             "reconnect_required",
             :authorization,
             now,
             %{
               error_class: error_attrs.last_error_class,
               error_code: error_attrs.last_error_code
             }
           ) do
      {:ok, authorization}
    end
  end

  defp maybe_mark_reconnect_required_locked(authorization, provider_error, now, opts) do
    with {:ok, applicability} <- reconnect_applicability(authorization, opts) do
      case applicability do
        :current ->
          with {:ok, authorization} <-
                 mark_reconnect_required_locked(authorization, provider_error, now, opts) do
            {:ok, :marked, authorization}
          end

        outcome when outcome in [:already_marked, :stale, :inactive] ->
          {:ok, outcome, authorization}
      end
    end
  end

  defp reconnect_applicability(%OAuthAuthorization{status: "connected"} = authorization, opts) do
    if live_dependent_methods?(authorization.id) do
      with {:ok, matches?} <- expected_access_token_matches?(authorization, opts) do
        {:ok, if(matches?, do: :current, else: :stale)}
      end
    else
      {:ok, :inactive}
    end
  end

  defp reconnect_applicability(%OAuthAuthorization{status: "reconnect_required"}, _opts),
    do: {:ok, :already_marked}

  defp reconnect_applicability(_authorization, _opts), do: {:ok, :inactive}

  defp live_dependent_methods?(authorization_id) do
    receive_live? =
      ReceiveMethod
      |> where(
        [method],
        method.oauth_authorization_id == ^authorization_id and method.status != "disconnected"
      )
      |> Repo.exists?()

    send_live? =
      SendMethod
      |> where(
        [method],
        method.oauth_authorization_id == ^authorization_id and method.status != "disconnected"
      )
      |> Repo.exists?()

    receive_live? or send_live?
  end

  defp expected_access_token_matches?(authorization, opts) do
    case Keyword.fetch(opts, :expected_access_token) do
      :error ->
        {:ok, true}

      {:ok, expected_access_token} when is_binary(expected_access_token) ->
        with {:ok, current_access_token} <- decrypt_access_token(authorization) do
          {:ok, secure_token_match?(current_access_token, expected_access_token)}
        end

      {:ok, _invalid} ->
        {:ok, false}
    end
  end

  defp secure_token_match?(left, right) do
    secure_digest_match?(:crypto.hash(:sha256, left), :crypto.hash(:sha256, right), 0)
  end

  defp secure_digest_match?(<<>>, <<>>, difference), do: difference == 0

  defp secure_digest_match?(
         <<left, left_rest::binary>>,
         <<right, right_rest::binary>>,
         difference
       ) do
    secure_digest_match?(left_rest, right_rest, bor(difference, bxor(left, right)))
  end

  defp persist(provider, consumed, purpose, token, identity, provider_address, cursors, now) do
    Repo.transaction(fn ->
      with {:ok, account, account_address} <- lock_account(consumed.mailbox_id),
           :ok <- require_matching_address(account_address, provider_address),
           {account_authorization, subject_authorization} <-
             lock_authorizations(provider, account.id, identity.id),
           :ok <-
             validate_binding(
               account_authorization,
               subject_authorization,
               account.id,
               identity.id
             ),
           {:ok, granted_scopes, event_type} <-
             validate_and_merge_scopes(
               provider,
               account_authorization,
               consumed,
               purpose,
               token.scopes
             ),
           {:ok, authorization} <-
             upsert_authorization(
               provider,
               account_authorization,
               account.id,
               identity.id,
               account_address.canonical,
               granted_scopes,
               token,
               now
             ),
           {:ok, method} <-
             upsert_method(
               provider,
               purpose,
               account.id,
               authorization,
               identity.id,
               account_address.canonical,
               granted_scopes,
               now
             ),
           :ok <- repair_dependent_method(provider, purpose, authorization),
           :ok <- persist_receive_state(purpose, method, cursors, now),
           {:ok, _event} <-
             insert_authorization_event(
               authorization.id,
               provider,
               event_type,
               purpose,
               now
             ) do
        {method, event_type}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {method, event_type}} -> {:ok, method, event_type}
      {:error, reason} -> {:error, normalize_constraint_error(reason)}
    end
  end

  defp lock_account(account_id) do
    case Accounts.active_account_for_update(Repo, account_id) do
      {:ok, %Account{} = account} ->
        account = Repo.preload(account, :domain)

        case Address.parse(Accounts.account_address(account)) do
          {:ok, address} -> {:ok, account, address}
          {:error, %CoreError{} = error} -> {:error, error}
        end

      {:error, %CoreError{} = error} ->
        {:error, error}
    end
  end

  defp require_matching_address(%Address{canonical: canonical}, %Address{canonical: canonical}),
    do: :ok

  defp require_matching_address(_account_address, _provider_address) do
    {:error,
     CoreError.new(
       :permanent,
       :provider_address_mismatch,
       "provider address does not match the account address"
     )}
  end

  defp lock_authorizations(provider, account_id, subject_id) do
    OAuthAuthorization
    |> where(
      [authorization],
      authorization.provider == ^provider and
        (authorization.account_id == ^account_id or
           authorization.provider_subject_id == ^subject_id)
    )
    |> order_by([authorization], asc: authorization.id)
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> then(fn authorizations ->
      {
        Enum.find(authorizations, &(&1.account_id == account_id)),
        Enum.find(authorizations, &(&1.provider_subject_id == subject_id))
      }
    end)
  end

  defp validate_binding(
         %OAuthAuthorization{provider_subject_id: existing_subject},
         _subject_authorization,
         _account_id,
         subject_id
       )
       when existing_subject != subject_id do
    {:error,
     CoreError.new(
       :permanent,
       :provider_identity_mismatch,
       "provider identity does not match the account's permanent binding"
     )}
  end

  defp validate_binding(
         _account_authorization,
         %OAuthAuthorization{account_id: existing_account_id},
         account_id,
         _subject_id
       )
       when existing_account_id != account_id do
    {:error,
     CoreError.new(
       :permanent,
       :provider_identity_already_bound,
       "provider identity is already bound to another account"
     )}
  end

  defp validate_binding(_account_authorization, _subject_authorization, _account_id, _subject_id),
    do: :ok

  defp validate_and_merge_scopes(provider, existing, consumed, purpose, token_scopes)
       when is_list(token_scopes) do
    required_from_consumed = MapSet.new(consumed.required_scopes)

    if Enum.all?(required_from_consumed, &OAuthScopes.approved?(provider, &1)) do
      stored = approved_scopes(provider, existing && existing.granted_scopes)

      required =
        MapSet.union(stored, required_from_consumed)
        |> MapSet.put(purpose_scope(provider, purpose))

      returned = approved_scopes(provider, token_scopes)
      granted = retain_durable_scopes(provider, returned, required)

      if MapSet.subset?(
           access_token_scopes(provider, required),
           access_token_scopes(provider, returned)
         ) do
        event_type =
          if existing && not MapSet.subset?(granted, stored),
            do: "scope_upgraded",
            else: "connected"

        {:ok, granted |> MapSet.to_list() |> Enum.sort(), event_type}
      else
        insufficient_scope(provider)
      end
    else
      insufficient_scope(provider)
    end
  end

  defp validate_and_merge_scopes(provider, _existing, _consumed, _purpose, _token_scopes),
    do: insufficient_scope(provider)

  defp approved_scopes(_provider, nil), do: MapSet.new()

  defp approved_scopes(provider, scopes) when is_list(scopes) do
    scopes
    |> MapSet.new()
    |> Enum.filter(&OAuthScopes.approved?(provider, &1))
    |> MapSet.new()
  end

  defp access_token_scopes("microsoft", scopes),
    do: MapSet.delete(scopes, MicrosoftScopes.offline())

  defp access_token_scopes(_provider, scopes), do: scopes

  defp retain_durable_scopes("microsoft", returned, required) do
    if MapSet.member?(required, MicrosoftScopes.offline()) do
      MapSet.put(returned, MicrosoftScopes.offline())
    else
      returned
    end
  end

  defp retain_durable_scopes(_provider, returned, _required), do: returned

  defp insufficient_scope(provider) do
    provider_name =
      case provider do
        "gmail" -> "Gmail"
        "microsoft" -> "Microsoft"
        _provider -> "provider"
      end

    {:error,
     CoreError.new(
       :permanent,
       :insufficient_provider_scope,
       "provider did not grant all required #{provider_name} scopes"
     )}
  end

  defp upsert_authorization(
         provider,
         existing,
         account_id,
         subject_id,
         email_address,
         granted_scopes,
         token,
         _now
       ) do
    authorization = existing || %OAuthAuthorization{id: Ecto.UUID.generate()}

    with {:ok, encrypted_access} <-
           Crypto.encrypt(token.access_token, credential_context(authorization.id, :access)),
         {:ok, encrypted_refresh} <-
           encrypted_refresh(token.refresh_token, existing, authorization.id) do
      attrs = %{
        account_id: account_id,
        provider: provider,
        provider_subject_id: subject_id,
        email_address: email_address,
        granted_scopes: granted_scopes,
        status: "connected",
        key_version: 1,
        access_token_ciphertext: encrypted_access,
        refresh_token_ciphertext: encrypted_refresh,
        token_expires_at: token.expires_at,
        last_error_class: nil,
        last_error_code: nil,
        last_error_message: nil,
        disconnected_at: nil
      }

      changeset = OAuthAuthorization.changeset(authorization, attrs)

      if existing do
        Repo.update(changeset)
      else
        Repo.insert(changeset)
      end
    end
  end

  defp encrypted_refresh(refresh_token, _existing, authorization_id)
       when is_binary(refresh_token) and refresh_token != "" do
    Crypto.encrypt(refresh_token, credential_context(authorization_id, :refresh))
  end

  defp encrypted_refresh(nil, %OAuthAuthorization{refresh_token_ciphertext: ciphertext}, _id)
       when is_binary(ciphertext),
       do: {:ok, ciphertext}

  defp encrypted_refresh(_refresh_token, _existing, _authorization_id) do
    {:error,
     CoreError.new(
       :permanent,
       :missing_refresh_token,
       "provider did not return a refresh token for a new connection"
     )}
  end

  defp upsert_method(
         provider,
         :receive,
         account_id,
         authorization,
         subject_id,
         email_address,
         granted_scopes,
         _now
       ) do
    existing =
      ReceiveMethod
      |> where([method], method.account_id == ^account_id and method.kind == ^provider)
      |> order_by([method], asc: method.id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    disable_other_receive_methods(account_id, existing && existing.id)

    attrs = %{
      account_id: account_id,
      oauth_authorization_id: authorization.id,
      kind: provider,
      provider_account_id: subject_id,
      email_address: email_address,
      status: "connected",
      enabled: true,
      sync_enabled: true,
      granted_scopes: granted_scopes,
      disconnected_at: nil,
      last_error_class: nil,
      last_error_code: nil,
      last_error_message: nil
    }

    changeset = ReceiveMethod.changeset(existing || %ReceiveMethod{}, attrs)
    if existing, do: Repo.update(changeset), else: Repo.insert(changeset)
  end

  defp upsert_method(
         provider,
         :send,
         account_id,
         authorization,
         _subject_id,
         email_address,
         _granted_scopes,
         _now
       ) do
    existing =
      SendMethod
      |> where([method], method.account_id == ^account_id and method.kind == ^provider)
      |> order_by([method], asc: method.id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    disable_other_send_methods(account_id, existing && existing.id)

    attrs = %{
      account_id: account_id,
      oauth_authorization_id: authorization.id,
      kind: provider,
      email_address: email_address,
      status: "connected",
      enabled: true,
      disconnected_at: nil,
      last_error_class: nil,
      last_error_code: nil,
      last_error_message: nil
    }

    changeset = SendMethod.changeset(existing || %SendMethod{}, attrs)
    if existing, do: Repo.update(changeset), else: Repo.insert(changeset)
  end

  defp disable_other_receive_methods(account_id, except_id) do
    ReceiveMethod
    |> where([method], method.account_id == ^account_id and method.enabled)
    |> maybe_except(except_id)
    |> Repo.update_all(set: [enabled: false, updated_at: DateTime.utc_now()])

    :ok
  end

  defp disable_other_send_methods(account_id, except_id) do
    SendMethod
    |> where([method], method.account_id == ^account_id and method.enabled)
    |> maybe_except(except_id)
    |> Repo.update_all(set: [enabled: false, updated_at: DateTime.utc_now()])

    :ok
  end

  defp repair_dependent_method(provider, :receive, authorization) do
    SendMethod
    |> where(
      [method],
      method.oauth_authorization_id == ^authorization.id and method.kind == ^provider and
        method.status == "reconnect_required"
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil ->
        :ok

      %SendMethod{} = method ->
        disable_other_send_methods(authorization.account_id, method.id)

        method
        |> SendMethod.changeset(%{
          status: "connected",
          enabled: true,
          disconnected_at: nil,
          last_error_class: nil,
          last_error_code: nil,
          last_error_message: nil
        })
        |> Repo.update()
        |> ok_result()
    end
  end

  defp repair_dependent_method(provider, :send, authorization) do
    ReceiveMethod
    |> where(
      [method],
      method.oauth_authorization_id == ^authorization.id and method.kind == ^provider and
        method.status == "reconnect_required"
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil ->
        :ok

      %ReceiveMethod{} = method ->
        disable_other_receive_methods(authorization.account_id, method.id)

        method
        |> ReceiveMethod.changeset(%{
          status: "connected",
          enabled: true,
          sync_enabled: true,
          disconnected_at: nil,
          last_error_class: nil,
          last_error_code: nil,
          last_error_message: nil
        })
        |> Repo.update()
        |> case do
          {:ok, repaired} ->
            _job = ensure_sync_job(repaired.id)
            :ok

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  defp ok_result({:ok, _value}), do: :ok
  defp ok_result({:error, reason}), do: {:error, reason}

  defp maybe_except(query, nil), do: query
  defp maybe_except(query, except_id), do: where(query, [method], method.id != ^except_id)

  defp persist_receive_state(:send, _method, [], _now), do: :ok

  defp persist_receive_state(:receive, method, cursors, now) do
    StoredCursor
    |> where([cursor], cursor.external_account_id == ^method.id)
    |> Repo.delete_all()

    rows =
      Enum.map(cursors, fn cursor ->
        %{
          id: Ecto.UUID.generate(),
          external_account_id: method.id,
          scope: cursor.scope,
          phase: cursor.phase,
          bootstrap_cursor: cursor.bootstrap_cursor,
          page_cursor: cursor.page_cursor,
          committed_cursor: cursor.committed_cursor,
          metadata: cursor.metadata,
          generation: 1,
          inserted_at: now,
          updated_at: now
        }
      end)

    {_count, _rows} = Repo.insert_all(StoredCursor, rows)
    _job = ensure_sync_job(method.id)
    :ok
  end

  defp ensure_sync_job(receive_method_id) do
    Oban.Job
    |> where([job], job.worker == ^inspect(SyncAccount))
    |> where([job], job.state in ~w(available scheduled executing retryable suspended))
    |> where(
      [job],
      fragment("?->>'external_account_id' = ?", job.args, ^receive_method_id)
    )
    |> order_by([job], asc: job.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      %Oban.Job{} = job ->
        job

      nil ->
        receive_method_id
        |> then(&SyncAccount.new(%{"external_account_id" => &1}))
        |> Repo.insert!()
    end
  end

  defp insert_authorization_event(
         authorization_id,
         provider,
         event_type,
         direction,
         now,
         extra_metadata \\ %{}
       ) do
    %ConnectorEvent{}
    |> ConnectorEvent.changeset(%{
      oauth_authorization_id: authorization_id,
      event_type: event_type,
      metadata:
        Map.merge(
          %{provider: provider, direction: Atom.to_string(direction)},
          extra_metadata
        ),
      occurred_at: now
    })
    |> Repo.insert()
  end

  defp public_complete_result({:ok, method, _outcome}), do: {:ok, method}
  defp public_complete_result(result), do: result

  defp emit_oauth_complete(consumed, {:ok, method, outcome}, start) do
    :telemetry.execute(
      [:manifold, :connectors, :oauth, :complete, :stop],
      telemetry_measurements(start),
      %{
        account_id: consumed.mailbox_id,
        authorization_id: method.oauth_authorization_id,
        method_id: method.id,
        provider: consumed.provider,
        method_kind: method.kind,
        outcome: oauth_complete_outcome(outcome)
      }
    )
  end

  defp emit_oauth_complete(consumed, {:error, reason}, start) do
    :telemetry.execute(
      [:manifold, :connectors, :oauth, :complete, :stop],
      telemetry_measurements(start),
      %{
        account_id: consumed.mailbox_id,
        provider: consumed.provider,
        method_kind: consumed.provider,
        outcome: :error,
        error_code: normalized_error_code(reason)
      }
    )
  end

  defp emit_oauth_complete(consumed, unexpected_result, start) do
    emit_oauth_complete(consumed, {:error, unexpected_result}, start)
  end

  defp oauth_complete_outcome("connected"), do: :connected
  defp oauth_complete_outcome("scope_upgraded"), do: :scope_upgraded

  defp emit_oauth_refresh(authorization, result, start) do
    {outcome, error_code} =
      case result do
        {:ok, _access_token} ->
          {:refreshed, nil}

        {:reconnect, %ProviderError{} = error} ->
          {:reconnect_required, normalized_error_code(error)}

        {:error, reason} ->
          {:error, normalized_error_code(reason)}
      end

    metadata = %{
      account_id: authorization.account_id,
      authorization_id: authorization.id,
      provider: authorization.provider,
      method_kind: authorization.provider,
      outcome: outcome
    }

    metadata = if error_code, do: Map.put(metadata, :error_code, error_code), else: metadata

    :telemetry.execute(
      [:manifold, :connectors, :oauth, :refresh, :stop],
      telemetry_measurements(start),
      metadata
    )
  end

  defp telemetry_measurements(start) do
    %{
      duration_ms:
        System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond),
      attempt_count: 1
    }
  end

  defp normalized_error_code(%CoreError{reason: reason}), do: telemetry_error_code(reason)
  defp normalized_error_code(%ProviderError{code: code}), do: telemetry_error_code(code)
  defp normalized_error_code(%Ecto.Changeset{}), do: :invalid_connector_state
  defp normalized_error_code(_reason), do: :connector_operation_failed

  defp telemetry_error_code(code) when is_atom(code) do
    if safe_telemetry_code?(Atom.to_string(code)), do: code, else: :connector_operation_failed
  end

  defp telemetry_error_code(code) when is_binary(code) do
    if safe_telemetry_code?(code), do: code, else: "connector_operation_failed"
  end

  defp telemetry_error_code(_code), do: :connector_operation_failed

  defp safe_telemetry_code?(code) do
    downcased = String.downcase(code)

    Regex.match?(@telemetry_code_pattern, downcased) and
      not Enum.any?(@telemetry_forbidden_fragments, &String.contains?(downcased, &1))
  end

  defp reconnect_error_attrs(provider, %ProviderError{} = error) do
    %{
      last_error_class: Atom.to_string(error.class),
      last_error_code: Atom.to_string(error.code),
      last_error_message: reconnect_message(provider)
    }
  end

  defp reconnect_message("gmail"), do: "Gmail authorization must be reconnected"
  defp reconnect_message("microsoft"), do: "Microsoft authorization must be reconnected"

  defp disable_dependent_methods(provider, authorization_id, error_attrs, now) do
    ReceiveMethod
    |> where(
      [method],
      method.oauth_authorization_id == ^authorization_id and method.kind == ^provider and
        method.status != "disconnected"
    )
    |> Repo.update_all(
      set: [
        status: "reconnect_required",
        enabled: false,
        sync_enabled: false,
        last_error_class: error_attrs.last_error_class,
        last_error_code: error_attrs.last_error_code,
        last_error_message: error_attrs.last_error_message,
        updated_at: now
      ],
      inc: [lock_version: 1]
    )

    SendMethod
    |> where(
      [method],
      method.oauth_authorization_id == ^authorization_id and method.kind == ^provider and
        method.status != "disconnected"
    )
    |> Repo.update_all(
      set: [
        status: "reconnect_required",
        enabled: false,
        last_error_class: error_attrs.last_error_class,
        last_error_code: error_attrs.last_error_code,
        last_error_message: error_attrs.last_error_message,
        updated_at: now
      ],
      inc: [lock_version: 1]
    )

    :ok
  end

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, CoreError.new(:temporary, point, "injected connector transaction failure")}
    else
      :ok
    end
  end

  defp initial_cursors(:send, _adapter, _token, _config, _provider_opts), do: {:ok, []}

  defp initial_cursors(:receive, adapter, token, config, provider_opts),
    do: adapter.initial_cursors(token.access_token, config, provider_opts)

  defp validate_cursors(:send, []), do: :ok

  defp validate_cursors(:receive, cursors) when is_list(cursors) and cursors != [] do
    if Enum.all?(cursors, &match?(%SyncCursor{}, &1)) do
      :ok
    else
      invalid_cursors()
    end
  end

  defp validate_cursors(_purpose, _cursors), do: invalid_cursors()

  defp invalid_cursors do
    {:error,
     CoreError.new(
       :permanent,
       :invalid_provider_cursors,
       "provider returned invalid sync cursors"
     )}
  end

  defp normalize_purpose(purpose) when purpose in [:receive, :send], do: {:ok, purpose}

  defp normalize_purpose(_purpose) do
    {:error, CoreError.new(:permanent, :invalid_oauth_purpose, "OAuth purpose is invalid")}
  end

  defp purpose_scope(provider, purpose) do
    {:ok, scope} = OAuthScopes.method_scope(provider, purpose)
    scope
  end

  defp method_scope(provider, purpose) do
    case OAuthScopes.method_scope(provider, purpose) do
      {:ok, scope} ->
        {:ok, scope}

      :error ->
        {:error,
         CoreError.new(
           :permanent,
           :unsupported_oauth_purpose,
           "OAuth purpose is not supported by provider"
         )}
    end
  end

  defp method_authorization_id(:receive, method_id),
    do: do_method_authorization_id(ReceiveMethod, method_id)

  defp method_authorization_id(:send, method_id),
    do: do_method_authorization_id(SendMethod, method_id)

  defp method_authorization_id(:receive, account_id, method_id),
    do: do_method_authorization_id(ReceiveMethod, account_id, method_id)

  defp method_authorization_id(:send, account_id, method_id),
    do: do_method_authorization_id(SendMethod, account_id, method_id)

  defp method_account_id(:receive, method_id), do: do_method_account_id(ReceiveMethod, method_id)

  defp do_method_account_id(schema, method_id) do
    schema
    |> where([method], method.id == ^method_id)
    |> select([method], method.account_id)
    |> Repo.one()
    |> case do
      nil -> {:error, method_not_found()}
      account_id -> {:ok, account_id}
    end
  end

  defp do_method_authorization_id(schema, method_id) do
    schema
    |> where([method], method.id == ^method_id)
    |> select([method], {method.kind, method.oauth_authorization_id})
    |> Repo.one()
    |> case do
      nil ->
        {:error, CoreError.new(:permanent, :account_not_found, "connector method not found")}

      {provider, authorization_id}
      when provider in @providers and is_binary(authorization_id) ->
        {:ok, authorization_id}

      _method ->
        {:error,
         CoreError.new(
           :permanent,
           :invalid_oauth_method,
           "connector method is not a supported OAuth method"
         )}
    end
  end

  defp do_method_authorization_id(schema, account_id, method_id) do
    schema
    |> where([method], method.id == ^method_id and method.account_id == ^account_id)
    |> select([method], {method.kind, method.oauth_authorization_id})
    |> Repo.one()
    |> case do
      nil ->
        {:error, method_not_found()}

      {provider, authorization_id}
      when provider in @providers and is_binary(authorization_id) ->
        {:ok, authorization_id}

      _method ->
        {:error,
         CoreError.new(
           :permanent,
           :invalid_oauth_method,
           "connector method is not a supported OAuth method"
         )}
    end
  end

  defp method_not_found,
    do: CoreError.new(:permanent, :account_not_found, "connector method not found")

  defp lock_method(:receive, method_id, authorization),
    do: do_lock_method(ReceiveMethod, method_id, authorization)

  defp lock_method(:send, method_id, authorization),
    do: do_lock_method(SendMethod, method_id, authorization)

  defp do_lock_method(
         schema,
         method_id,
         %OAuthAuthorization{
           id: authorization_id,
           account_id: account_id,
           provider: provider
         }
       ) do
    schema
    |> where([method], method.id == ^method_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil ->
        {:error, CoreError.new(:permanent, :account_not_found, "connector method not found")}

      %{
        kind: ^provider,
        oauth_authorization_id: ^authorization_id,
        account_id: ^account_id
      } = method ->
        {:ok, method}

      _method ->
        {:error,
         CoreError.new(
           :permanent,
           :invalid_oauth_method,
           "connector method is not a supported OAuth method"
         )}
    end
  end

  defp disconnect_locked_method(:receive, %ReceiveMethod{status: "disconnected"} = method, _now) do
    method
    |> ReceiveMethod.changeset(%{})
    |> Ecto.Changeset.force_change(:status, method.status)
    |> Repo.update()
  end

  defp disconnect_locked_method(:receive, %ReceiveMethod{} = method, now) do
    method
    |> ReceiveMethod.changeset(%{
      status: "disconnected",
      enabled: false,
      sync_enabled: false,
      disconnected_at: now,
      last_error_class: nil,
      last_error_code: nil,
      last_error_message: nil
    })
    |> Repo.update()
  end

  defp disconnect_locked_method(:send, %SendMethod{status: "disconnected"} = method, _now) do
    method
    |> SendMethod.changeset(%{})
    |> Ecto.Changeset.force_change(:status, method.status)
    |> Repo.update()
  end

  defp disconnect_locked_method(:send, %SendMethod{} = method, now) do
    method
    |> SendMethod.changeset(%{
      status: "disconnected",
      enabled: false,
      disconnected_at: now,
      last_error_class: nil,
      last_error_code: nil,
      last_error_message: nil
    })
    |> Repo.update()
  end

  defp delete_method_secrets(:receive, method_id) do
    Credential
    |> where([credential], credential.external_account_id == ^method_id)
    |> Repo.delete_all()

    :ok
  end

  defp delete_method_secrets(:send, method_id) do
    SendCredential
    |> where([credential], credential.send_method_id == ^method_id)
    |> Repo.delete_all()

    SmtpSettings
    |> where([settings], settings.send_method_id == ^method_id)
    |> Repo.delete_all()

    :ok
  end

  defp cancel_receive_jobs(method_id) do
    Oban.Job
    |> where([job], job.worker == ^inspect(SyncAccount))
    |> where([job], job.state in ~w(available scheduled retryable suspended))
    |> where(
      [job],
      fragment("?->>'external_account_id' = ?", job.args, ^method_id)
    )
    |> Repo.delete_all()

    :ok
  end

  defp lock_authorization(authorization_id) do
    OAuthAuthorization
    |> where([authorization], authorization.id == ^authorization_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %OAuthAuthorization{} = authorization ->
        {:ok, authorization}

      nil ->
        {:error, CoreError.new(:permanent, :authorization_not_found, "authorization not found")}
    end
  end

  defp lock_account_authorization(provider, account_id) do
    OAuthAuthorization
    |> where(
      [authorization],
      authorization.provider == ^provider and authorization.account_id == ^account_id
    )
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      %OAuthAuthorization{} = authorization ->
        {:ok, authorization}

      nil ->
        {:error, CoreError.new(:permanent, :authorization_not_found, "authorization not found")}
    end
  end

  defp maybe_disconnect_authorization(authorization, now) do
    receive_count =
      ReceiveMethod
      |> where(
        [method],
        method.oauth_authorization_id == ^authorization.id and method.status != "disconnected"
      )
      |> Repo.aggregate(:count)

    send_count =
      SendMethod
      |> where(
        [method],
        method.oauth_authorization_id == ^authorization.id and method.status != "disconnected"
      )
      |> Repo.aggregate(:count)

    cond do
      receive_count + send_count == 0 and authorization.status == "disconnected" ->
        authorization
        |> OAuthAuthorization.changeset(%{})
        |> Ecto.Changeset.force_change(:status, authorization.status)
        |> Repo.update()

      receive_count + send_count == 0 ->
        authorization
        |> OAuthAuthorization.changeset(%{
          status: "disconnected",
          access_token_ciphertext: nil,
          refresh_token_ciphertext: nil,
          token_expires_at: nil,
          disconnected_at: now,
          last_error_class: nil,
          last_error_code: nil,
          last_error_message: nil
        })
        |> Repo.update()

      true ->
        authorization
        |> OAuthAuthorization.changeset(%{})
        |> Ecto.Changeset.force_change(:status, authorization.status)
        |> Repo.update()
    end
  end

  defp normalize_constraint_error(%Ecto.Changeset{} = changeset) do
    cond do
      constraint_error?(
        changeset,
        "connector_oauth_authorizations_provider_subject_index"
      ) ->
        CoreError.new(
          :permanent,
          :provider_identity_already_bound,
          "provider identity is already bound to another account"
        )

      constraint_error?(
        changeset,
        "connector_oauth_authorizations_mailbox_id_provider_index"
      ) ->
        CoreError.new(
          :permanent,
          :provider_identity_mismatch,
          "provider identity does not match the account's permanent binding"
        )

      true ->
        changeset
    end
  end

  defp normalize_constraint_error(reason), do: reason

  defp constraint_error?(changeset, constraint_name) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      metadata[:constraint_name] && to_string(metadata[:constraint_name]) == constraint_name
    end)
  end

  defp credential_context(authorization_id, kind),
    do: "credential:#{authorization_id}:#{kind}"

  defp provider_error(%ProviderError{} = error) do
    class = if error.class == :temporary, do: :temporary, else: :permanent

    CoreError.new(class, error.code, error.message, %{
      provider_class: error.class,
      retry_after_seconds: error.retry_after_seconds
    })
  end

  defp database_error do
    CoreError.new(:temporary, :database_unavailable, "connector database is unavailable")
  end

  defp normalize_transaction_error(
         %Postgrex.Error{postgres: %{code: code}},
         _stacktrace
       )
       when code in [:deadlock_detected, :serialization_failure] do
    {:error, database_error()}
  end

  defp normalize_transaction_error(error, stacktrace), do: reraise(error, stacktrace)
end

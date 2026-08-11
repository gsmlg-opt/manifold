defmodule Manifold.Connectors.GmailAuthorizations do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Accounts
  alias Manifold.Accounts.Schema.Account
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.GmailScopes
  alias Manifold.Connectors.Jobs.SyncAccount
  alias Manifold.Connectors.OAuth.Consumed
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

  @provider "gmail"
  @approved_scopes MapSet.new([GmailScopes.read(), GmailScopes.send()])

  @spec complete(String.t(), Consumed.t(), module(), keyword(), keyword()) ::
          {:ok, ReceiveMethod.t() | SendMethod.t()}
          | {:error, CoreError.t() | Ecto.Changeset.t()}
  def complete(code, consumed, adapter, config, opts \\ [])

  def complete(code, %Consumed{provider: @provider} = consumed, adapter, config, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    provider_opts = Keyword.get(opts, :provider_opts, [])

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
      persist(consumed, purpose, token, identity, provider_address, cursors, now)
    else
      {:error, %ProviderError{} = error} -> {:error, provider_error(error)}
      {:error, %CoreError{} = error} -> {:error, error}
    end
  rescue
    DBConnection.ConnectionError ->
      {:error, database_error()}

    error in Postgrex.Error ->
      normalize_transaction_error(error, __STACKTRACE__)
  end

  def complete(_code, %Consumed{}, _adapter, _config, _opts) do
    {:error, CoreError.new(:permanent, :oauth_provider_mismatch, "OAuth provider does not match")}
  end

  @spec disconnect_method(:receive | :send, Ecto.UUID.t()) ::
          {:ok, ReceiveMethod.t() | SendMethod.t()}
          | {:error, CoreError.t() | Ecto.Changeset.t()}
  def disconnect_method(direction, method_id) when direction in [:receive, :send] do
    now = DateTime.utc_now()

    with {:ok, authorization_id} <- method_authorization_id(direction, method_id) do
      Repo.transaction(fn ->
        with {:ok, authorization} <- lock_authorization(authorization_id),
             {:ok, method} <- lock_method(direction, method_id, authorization),
             {:ok, disconnected} <- disconnect_locked_method(direction, method, now),
             :ok <- delete_method_secrets(direction, method.id),
             {:ok, _authorization} <- maybe_disconnect_authorization(authorization, now),
             {:ok, _event} <-
               insert_authorization_event(authorization.id, "disconnected", direction, now) do
          disconnected
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

  @spec delete_receive_method(Ecto.UUID.t()) ::
          {:ok, ReceiveMethod.t()} | {:error, CoreError.t() | Ecto.Changeset.t()}
  def delete_receive_method(method_id) do
    now = DateTime.utc_now()

    with {:ok, authorization_id} <- method_authorization_id(:receive, method_id) do
      Repo.transaction(fn ->
        with {:ok, authorization} <- lock_authorization(authorization_id),
             {:ok, method} <- lock_method(:receive, method_id, authorization),
             :ok <- cancel_receive_jobs(method.id),
             {:ok, deleted} <- Repo.delete(method),
             {:ok, _authorization} <- maybe_disconnect_authorization(authorization, now),
             {:ok, _event} <-
               insert_authorization_event(authorization.id, "disconnected", :receive, now) do
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
    now = Keyword.get(opts, :now, DateTime.utc_now())
    error_attrs = reconnect_error_attrs(provider_error)

    Repo.transaction(fn ->
      with {:ok, authorization} <- lock_authorization(authorization_id),
           {:ok, authorization} <-
             authorization
             |> OAuthAuthorization.changeset(
               Map.merge(error_attrs, %{status: "reconnect_required", disconnected_at: nil})
             )
             |> Repo.update(),
           :ok <- disable_dependent_methods(authorization.id, error_attrs, now),
           :ok <- maybe_fault(opts, :after_methods_before_event),
           {:ok, _event} <-
             insert_authorization_event(
               authorization.id,
               "reconnect_required",
               :authorization,
               now,
               %{
                 error_class: error_attrs.last_error_class,
                 error_code: error_attrs.last_error_code
               }
             ) do
        authorization
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, authorization} -> {:ok, authorization}
      {:error, reason} -> {:error, reason}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error()}
    error in Postgrex.Error -> normalize_transaction_error(error, __STACKTRACE__)
  end

  defp persist(consumed, purpose, token, identity, provider_address, cursors, now) do
    Repo.transaction(fn ->
      with {:ok, account, account_address} <- lock_account(consumed.mailbox_id),
           :ok <- require_matching_address(account_address, provider_address),
           {account_authorization, subject_authorization} <-
             lock_authorizations(account.id, identity.id),
           :ok <-
             validate_binding(
               account_authorization,
               subject_authorization,
               account.id,
               identity.id
             ),
           {:ok, granted_scopes, event_type} <-
             validate_and_merge_scopes(account_authorization, consumed, purpose, token.scopes),
           {:ok, authorization} <-
             upsert_authorization(
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
               purpose,
               account.id,
               authorization,
               identity.id,
               account_address.canonical,
               granted_scopes,
               now
             ),
           :ok <- repair_dependent_method(purpose, authorization),
           :ok <- persist_receive_state(purpose, method, cursors, now),
           {:ok, _event} <-
             insert_authorization_event(authorization.id, event_type, purpose, now) do
        method
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, method} -> {:ok, method}
      {:error, reason} -> {:error, normalize_constraint_error(reason)}
    end
  end

  defp lock_account(account_id) do
    account =
      Account
      |> where([account], account.id == ^account_id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    case account do
      nil ->
        {:error, CoreError.new(:permanent, :account_not_found, "account not found")}

      %Account{} = account ->
        account = Repo.preload(account, :domain)

        case Address.parse(Accounts.account_address(account)) do
          {:ok, address} -> {:ok, account, address}
          {:error, %CoreError{} = error} -> {:error, error}
        end
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

  defp lock_authorizations(account_id, subject_id) do
    OAuthAuthorization
    |> where(
      [authorization],
      authorization.provider == @provider and
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

  defp validate_and_merge_scopes(existing, consumed, purpose, token_scopes)
       when is_list(token_scopes) do
    required_from_consumed = MapSet.new(consumed.required_scopes)

    if MapSet.subset?(required_from_consumed, @approved_scopes) do
      stored = approved_scopes(existing && existing.granted_scopes)

      required =
        MapSet.union(stored, required_from_consumed) |> MapSet.put(purpose_scope(purpose))

      granted = approved_scopes(token_scopes)

      if MapSet.subset?(required, granted) do
        event_type =
          if existing && not MapSet.subset?(granted, stored),
            do: "scope_upgraded",
            else: "connected"

        {:ok, granted |> MapSet.to_list() |> Enum.sort(), event_type}
      else
        insufficient_scope()
      end
    else
      insufficient_scope()
    end
  end

  defp validate_and_merge_scopes(_existing, _consumed, _purpose, _token_scopes),
    do: insufficient_scope()

  defp approved_scopes(nil), do: MapSet.new()

  defp approved_scopes(scopes) when is_list(scopes) do
    scopes
    |> MapSet.new()
    |> MapSet.intersection(@approved_scopes)
  end

  defp insufficient_scope do
    {:error,
     CoreError.new(
       :permanent,
       :insufficient_provider_scope,
       "provider did not grant all required Gmail scopes"
     )}
  end

  defp upsert_authorization(
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
        provider: @provider,
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
      |> where([method], method.account_id == ^account_id and method.kind == @provider)
      |> order_by([method], asc: method.id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    disable_other_receive_methods(account_id, existing && existing.id)

    attrs = %{
      account_id: account_id,
      oauth_authorization_id: authorization.id,
      kind: @provider,
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
      |> where([method], method.account_id == ^account_id and method.kind == @provider)
      |> order_by([method], asc: method.id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    disable_other_send_methods(account_id, existing && existing.id)

    attrs = %{
      account_id: account_id,
      oauth_authorization_id: authorization.id,
      kind: @provider,
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

  defp repair_dependent_method(:receive, authorization) do
    SendMethod
    |> where(
      [method],
      method.oauth_authorization_id == ^authorization.id and method.kind == @provider and
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

  defp repair_dependent_method(:send, authorization) do
    ReceiveMethod
    |> where(
      [method],
      method.oauth_authorization_id == ^authorization.id and method.kind == @provider and
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

  defp persist_receive_state(:send, _method, nil, _now), do: :ok

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
          %{provider: @provider, direction: Atom.to_string(direction)},
          extra_metadata
        ),
      occurred_at: now
    })
    |> Repo.insert()
  end

  defp reconnect_error_attrs(%ProviderError{} = error) do
    %{
      last_error_class: Atom.to_string(error.class),
      last_error_code: Atom.to_string(error.code),
      last_error_message: "Gmail authorization must be reconnected"
    }
  end

  defp disable_dependent_methods(authorization_id, error_attrs, now) do
    ReceiveMethod
    |> where(
      [method],
      method.oauth_authorization_id == ^authorization_id and method.kind == @provider and
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
      ]
    )

    SendMethod
    |> where(
      [method],
      method.oauth_authorization_id == ^authorization_id and method.kind == @provider and
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
      ]
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

  defp initial_cursors(:send, _adapter, _token, _config, _provider_opts), do: {:ok, nil}

  defp initial_cursors(:receive, adapter, token, config, provider_opts),
    do: adapter.initial_cursors(token.access_token, config, provider_opts)

  defp validate_cursors(:send, nil), do: :ok

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

  defp purpose_scope(:receive), do: GmailScopes.read()
  defp purpose_scope(:send), do: GmailScopes.send()

  defp method_authorization_id(:receive, method_id),
    do: do_method_authorization_id(ReceiveMethod, method_id)

  defp method_authorization_id(:send, method_id),
    do: do_method_authorization_id(SendMethod, method_id)

  defp do_method_authorization_id(schema, method_id) do
    schema
    |> where([method], method.id == ^method_id)
    |> select([method], {method.kind, method.oauth_authorization_id})
    |> Repo.one()
    |> case do
      nil ->
        {:error, CoreError.new(:permanent, :account_not_found, "connector method not found")}

      {@provider, authorization_id} when is_binary(authorization_id) ->
        {:ok, authorization_id}

      _method ->
        {:error,
         CoreError.new(:permanent, :invalid_gmail_method, "connector method is not Gmail")}
    end
  end

  defp lock_method(:receive, method_id, authorization),
    do: do_lock_method(ReceiveMethod, method_id, authorization)

  defp lock_method(:send, method_id, authorization),
    do: do_lock_method(SendMethod, method_id, authorization)

  defp do_lock_method(
         schema,
         method_id,
         %OAuthAuthorization{id: authorization_id, account_id: account_id}
       ) do
    schema
    |> where([method], method.id == ^method_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil ->
        {:error, CoreError.new(:permanent, :account_not_found, "connector method not found")}

      %{
        kind: @provider,
        oauth_authorization_id: ^authorization_id,
        account_id: ^account_id
      } = method ->
        {:ok, method}

      _method ->
        {:error,
         CoreError.new(:permanent, :invalid_gmail_method, "connector method is not Gmail")}
    end
  end

  defp disconnect_locked_method(:receive, %ReceiveMethod{status: "disconnected"} = method, _now),
    do: {:ok, method}

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

  defp disconnect_locked_method(:send, %SendMethod{status: "disconnected"} = method, _now),
    do: {:ok, method}

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

    if receive_count + send_count == 0 do
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
    else
      {:ok, authorization}
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

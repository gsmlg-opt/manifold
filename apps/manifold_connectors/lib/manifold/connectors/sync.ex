defmodule Manifold.Connectors.Sync do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Accounts
  alias Manifold.Connectors.Crypto
  alias Manifold.Connectors.Jobs.ApplyRemoteState
  alias Manifold.Connectors.Provider
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Connectors.Provider.{Page, RawMessage}
  alias Manifold.Connectors.Provider.RemoteMessage, as: ProviderMessage
  alias Manifold.Connectors.Provider.SyncCursor, as: ProviderCursor

  alias Manifold.Connectors.Schema.{
    ConnectorEvent,
    Credential,
    ExternalAccount,
    ImapSettings,
    RemoteMessage,
    SyncCursor
  }

  alias Manifold.Core.Error
  alias Manifold.Ingest
  alias Manifold.Ingest.ExternalSource
  alias Manifold.Repo

  @refresh_skew_seconds 60
  @default_retry_seconds 30

  @spec run(Ecto.UUID.t(), Keyword.t()) ::
          :ok | {:snooze, pos_integer()} | {:cancel, atom()} | {:error, term()}
  def run(account_id, opts \\ []) do
    start = System.monotonic_time()
    now = Keyword.get(opts, :now, DateTime.utc_now())

    try do
      case do_run(account_id, now, opts) do
        {:ok, provider, message_count, outcome} ->
          emit_sync_stop(account_id, start, provider, :ok, %{
            message_count: message_count,
            page_count: 1
          })

          outcome

        {:error, provider, error, outcome} ->
          emit_sync_stop(account_id, start, provider, error, %{message_count: 0, page_count: 0})
          outcome
      end
    rescue
      DBConnection.ConnectionError ->
        emit_sync_stop(account_id, start, "unknown", :database_unavailable, %{
          message_count: 0,
          page_count: 0
        })

        {:error,
         Error.new(:temporary, :database_unavailable, "connector database is unavailable")}
    end
  end

  defp do_run(account_id, now, opts) do
    with {:ok, account, cursor} <- begin_sync(account_id, now),
         {:ok, adapter, config} <- runtime(account.provider),
         {:ok, config} <- enrich_runtime_config(account, config),
         {:ok, auth} <-
           auth_material(account, adapter, config, now, provider_opts(opts)) do
      opts = prepare_provider_session(account, adapter, opts)

      try do
        with {:ok, %Page{} = page} <-
               sync_page(adapter, auth, cursor, config, provider_opts(opts)),
             messages = collapse_messages(page.messages),
             :ok <-
               process_messages(
                 messages,
                 account,
                 adapter,
                 config,
                 auth,
                 now,
                 opts
               ),
             :ok <- maybe_fault(opts, :after_page_before_cursor),
             {:ok, more?} <- checkpoint(account, cursor, page, now) do
          outcome = if more?, do: {:snooze, 1}, else: :ok
          {:ok, account.provider, length(messages), outcome}
        else
          {:error, {:cursor_provider_error, cursor, %ProviderError{} = error}} ->
            {:error, "imap", error, handle_cursor_provider_error(account_id, cursor, error, now)}

          {:error, %ProviderError{} = error} ->
            {:error, account.provider, error, handle_provider_error(account_id, error, now)}

          {:error, %Error{} = error} ->
            {:error, account.provider, error, handle_core_error(account_id, error, now)}

          {:error, reason} ->
            error =
              Error.new(:temporary, :sync_failed, "connector synchronization failed", %{
                reason: inspect(reason)
              })

            record_failure(account_id, error.class, error.reason, error.message, now)
            {:error, account.provider, error, {:error, error}}
        end
      after
        release_provider_session(adapter)
      end
    else
      {:error, {:cursor_provider_error, cursor, %ProviderError{} = error}} ->
        {:error, "imap", error, handle_cursor_provider_error(account_id, cursor, error, now)}

      {:error, %ProviderError{} = error} ->
        {:error, "imap", error, handle_provider_error(account_id, error, now)}

      {:error, %Error{} = error} ->
        {:error, "unknown", error, handle_core_error(account_id, error, now)}

      {:error, reason} ->
        error =
          Error.new(:temporary, :sync_failed, "connector synchronization failed", %{
            reason: inspect(reason)
          })

        record_failure(account_id, error.class, error.reason, error.message, now)
        {:error, "unknown", error, {:error, error}}
    end
  end

  defp prepare_provider_session(%ExternalAccount{provider: "imap"}, adapter, opts) do
    if function_exported?(adapter, :release_session, 0) do
      Keyword.update(
        opts,
        :provider_opts,
        [retain_session: true],
        &Keyword.put(&1, :retain_session, true)
      )
    else
      opts
    end
  end

  defp prepare_provider_session(_account, _adapter, opts), do: opts

  defp release_provider_session(adapter) do
    if function_exported?(adapter, :release_session, 0) do
      adapter.release_session()
    else
      :ok
    end
  end

  defp emit_sync_stop(account_id, start, provider, :ok, counts) do
    :telemetry.execute(
      [:manifold, :connectors, :sync, :stop],
      Map.merge(%{duration_ms: duration_ms(start)}, counts),
      %{account_id: account_id, provider: provider, result: :ok}
    )
  end

  defp emit_sync_stop(account_id, start, provider, %ProviderError{} = error, counts) do
    :telemetry.execute(
      [:manifold, :connectors, :sync, :stop],
      Map.merge(%{duration_ms: duration_ms(start)}, counts),
      %{
        account_id: account_id,
        provider: provider,
        result: :error,
        error_code: error.code,
        error_message: error.message
      }
    )
  end

  defp emit_sync_stop(account_id, start, provider, %Error{} = error, counts) do
    :telemetry.execute(
      [:manifold, :connectors, :sync, :stop],
      Map.merge(%{duration_ms: duration_ms(start)}, counts),
      %{
        account_id: account_id,
        provider: provider,
        result: :error,
        error_code: error.reason,
        error_message: error.message
      }
    )
  end

  defp emit_sync_stop(account_id, start, provider, :database_unavailable, counts) do
    :telemetry.execute(
      [:manifold, :connectors, :sync, :stop],
      Map.merge(%{duration_ms: duration_ms(start)}, counts),
      %{
        account_id: account_id,
        provider: provider,
        result: :error,
        error_code: :database_unavailable,
        error_message: "connector database is unavailable"
      }
    )
  end

  defp duration_ms(start) do
    System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
  end

  defp sync_page(adapter, access_token, cursor, config, opts) do
    case adapter.sync_page(access_token, provider_cursor(cursor), config, opts) do
      {:ok, %Page{} = page} -> {:ok, page}
      {:error, %ProviderError{} = error} -> {:error, {:cursor_provider_error, cursor, error}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp begin_sync(account_id, now) do
    Repo.transaction(fn ->
      account =
        ExternalAccount
        |> where([account], account.id == ^account_id)
        |> lock("FOR UPDATE")
        |> Repo.one()

      case account do
        nil ->
          Repo.rollback(Error.new(:permanent, :account_not_found, "connector account not found"))

        %ExternalAccount{status: "disconnected"} ->
          Repo.rollback(
            Error.new(:permanent, :account_disconnected, "connector account is disconnected")
          )

        %ExternalAccount{sync_enabled: false} ->
          Repo.rollback(Error.new(:permanent, :sync_disabled, "connector sync is disabled"))

        %ExternalAccount{} = account ->
          cursor = next_cursor(account.id)

          if cursor do
            {:ok, syncing} =
              account
              |> ExternalAccount.changeset(%{
                status: "syncing",
                last_attempted_at: now,
                last_error_class: nil,
                last_error_code: nil,
                last_error_message: nil
              })
              |> Repo.update()

            {syncing, cursor}
          else
            Repo.rollback(
              Error.new(:permanent, :sync_cursor_missing, "connector sync cursor is missing")
            )
          end
      end
    end)
    |> case do
      {:ok, {account, cursor}} -> {:ok, account, cursor}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_cursor(account_id) do
    SyncCursor
    |> where([cursor], cursor.external_account_id == ^account_id)
    |> order_by(
      [cursor],
      asc:
        fragment(
          "CASE WHEN ? IS NOT NULL THEN 0 WHEN ? IS NULL THEN 1 ELSE 2 END",
          cursor.page_cursor,
          cursor.last_completed_at
        ),
      asc_nulls_first: cursor.last_completed_at,
      asc: cursor.scope
    )
    |> limit(1)
    |> Repo.one()
  end

  defp auth_material(%ExternalAccount{provider: "imap"} = account, _adapter, _config, _now, _opts) do
    with %Credential{secret_kind: "password", password_ciphertext: cipher} <-
           Repo.get_by(Credential, external_account_id: account.id),
         {:ok, password} <- Crypto.decrypt(cipher, credential_context(account.id, :imap_password)) do
      {:ok, password}
    else
      nil ->
        {:error, Error.new(:permanent, :credential_missing, "connector credential is missing")}

      %Credential{} ->
        {:error,
         Error.new(
           :permanent,
           :credential_kind_mismatch,
           "IMAP account requires a password credential"
         )}

      {:error, _} = error ->
        error
    end
  end

  defp auth_material(account, adapter, config, now, opts),
    do: access_token(account, adapter, config, now, opts)

  defp access_token(account, adapter, config, now, provider_opts) do
    case Repo.get_by(Credential, external_account_id: account.id) do
      nil ->
        {:error, Error.new(:permanent, :credential_missing, "connector credential is missing")}

      %Credential{} = credential ->
        if token_current?(credential, now) do
          Crypto.decrypt(
            credential.access_token_ciphertext,
            credential_context(account.id, :access)
          )
        else
          refresh_access_token(account, credential, adapter, config, now, provider_opts)
        end
    end
  end

  defp token_current?(credential, now) do
    is_binary(credential.access_token_ciphertext) and
      match?(%DateTime{}, credential.token_expires_at) and
      DateTime.compare(
        credential.token_expires_at,
        DateTime.add(now, @refresh_skew_seconds, :second)
      ) == :gt
  end

  defp refresh_access_token(account, credential, adapter, config, now, provider_opts) do
    with {:ok, refresh_token} <-
           Crypto.decrypt(
             credential.refresh_token_ciphertext,
             credential_context(account.id, :refresh)
           ),
         {:ok, %Provider.Token{} = token} <-
           adapter.refresh_token(
             refresh_token,
             config,
             Keyword.put_new(provider_opts, :now, now)
           ),
         {:ok, _credential} <- persist_refreshed_token(account.id, token) do
      {:ok, token.access_token}
    end
  end

  defp persist_refreshed_token(account_id, token) do
    Repo.transaction(fn ->
      credential =
        Credential
        |> where([credential], credential.external_account_id == ^account_id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      with {:ok, encrypted_access} <-
             Crypto.encrypt(token.access_token, credential_context(account_id, :access)),
           {:ok, encrypted_refresh} <-
             refreshed_token_ciphertext(account_id, credential, token.refresh_token) do
        credential
        |> Credential.changeset(%{
          access_token_ciphertext: encrypted_access,
          refresh_token_ciphertext: encrypted_refresh,
          token_expires_at: token.expires_at
        })
        |> Repo.update!()
      else
        {:error, %Error{} = error} -> Repo.rollback(error)
      end
    end)
  end

  defp refreshed_token_ciphertext(_account_id, credential, nil),
    do: {:ok, credential.refresh_token_ciphertext}

  defp refreshed_token_ciphertext(account_id, _credential, refresh_token) do
    Crypto.encrypt(refresh_token, credential_context(account_id, :refresh))
  end

  defp process_messages(messages, account, adapter, config, access_token, now, opts) do
    Enum.reduce_while(messages, :ok, fn message, :ok ->
      case process_message(message, account, adapter, config, access_token, now, opts) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp process_message(
         %ProviderMessage{
           id: message_id,
           folder_kind: folder_kind,
           tombstone_kind: :membership
         } = message,
         account,
         adapter,
         config,
         token,
         now,
         opts
       ) do
    case adapter.fetch_raw(token, message_id, config, provider_opts(opts)) do
      {:ok, %RawMessage{}} ->
        :ok

      {:error, %ProviderError{code: :not_found}} ->
        with {:ok, delivery_id} <- accepted_delivery_id(account, message) do
          upsert_remote_message(
            account,
            %{message | deleted?: true, folder_kind: folder_kind},
            delivery_id,
            "deleted",
            now
          )
        end

      {:error, %ProviderError{} = error} ->
        {:error, error}
    end
  end

  defp process_message(%ProviderMessage{} = message, account, adapter, config, token, now, opts) do
    with {:ok, delivery_id} <- accepted_delivery_id(account, message) do
      cond do
        message.deleted? ->
          upsert_remote_message(account, message, delivery_id, "deleted", now)

        is_binary(delivery_id) ->
          upsert_remote_message(account, message, delivery_id, "imported", now)

        true ->
          import_remote_message(message, account, adapter, config, token, now, opts)
      end
    end
  end

  defp accepted_delivery_id(account, message) do
    case Repo.get_by(RemoteMessage,
           external_account_id: account.id,
           provider_message_id: message.id
         ) do
      %RemoteMessage{inbound_delivery_id: delivery_id} when is_binary(delivery_id) ->
        {:ok, delivery_id}

      _missing_or_pending ->
        case Ingest.lookup_external(account.provider, account.id, message.id) do
          {:ok, receipt} ->
            {:ok, receipt.inbound_delivery_id}

          {:error, %Error{reason: :external_ingress_not_found}} ->
            {:ok, nil}

          {:error, %Error{} = error} ->
            {:error, error}
        end
    end
  end

  defp import_remote_message(message, account, adapter, config, token, now, opts) do
    start = System.monotonic_time()

    case adapter.fetch_raw(token, message.id, config, provider_opts(opts)) do
      {:ok, %RawMessage{} = raw} ->
        case import_raw_message(message, raw, account, now, opts) do
          :ok ->
            emit_message_stop(account, message.id, start, :ok)
            :ok

          {:error, reason} = error ->
            emit_message_stop(account, message.id, start, reason)
            error
        end

      {:error, %ProviderError{code: :not_found}} ->
        case upsert_remote_message(account, %{message | deleted?: true}, nil, "deleted", now) do
          :ok ->
            emit_message_stop(account, message.id, start, :ok)
            :ok

          {:error, reason} = upsert_error ->
            emit_message_stop(account, message.id, start, reason)
            upsert_error
        end

      {:error, %ProviderError{} = error} ->
        emit_message_stop(account, message.id, start, error)
        {:error, error}
    end
  end

  defp emit_message_stop(account, provider_message_id, start, :ok) do
    :telemetry.execute(
      [:manifold, :connectors, :sync, :message, :stop],
      %{duration_ms: duration_ms(start)},
      %{
        account_id: account.id,
        provider: account.provider,
        provider_message_id: provider_message_id,
        result: :ok
      }
    )
  end

  defp emit_message_stop(account, provider_message_id, start, %ProviderError{} = error) do
    :telemetry.execute(
      [:manifold, :connectors, :sync, :message, :stop],
      %{duration_ms: duration_ms(start)},
      %{
        account_id: account.id,
        provider: account.provider,
        provider_message_id: provider_message_id,
        result: :error,
        error_code: error.code,
        error_message: error.message
      }
    )
  end

  defp emit_message_stop(account, provider_message_id, start, %Error{} = error) do
    :telemetry.execute(
      [:manifold, :connectors, :sync, :message, :stop],
      %{duration_ms: duration_ms(start)},
      %{
        account_id: account.id,
        provider: account.provider,
        provider_message_id: provider_message_id,
        result: :error,
        error_code: error.reason,
        error_message: error.message
      }
    )
  end

  defp emit_message_stop(account, provider_message_id, start, reason) do
    :telemetry.execute(
      [:manifold, :connectors, :sync, :message, :stop],
      %{duration_ms: duration_ms(start)},
      %{
        account_id: account.id,
        provider: account.provider,
        provider_message_id: provider_message_id,
        result: :error,
        error_code: :sync_message_failed,
        error_message: inspect(reason)
      }
    )
  end

  defp import_raw_message(message, raw, account, now, opts) do
    with :ok <- validate_raw_size(raw.bytes),
         {:ok, storage_domain_id} <- Accounts.mailbox_domain_id(account.mailbox_id),
         merged = merge_remote_state(message, raw),
         source = external_source(account, storage_domain_id, merged, raw, now),
         {:ok, receipt} <-
           Ingest.import_external(
             raw.bytes,
             source,
             ingest_opts(opts)
           ),
         :ok <- maybe_fault(opts, :after_external_accept_before_mapping),
         :ok <-
           upsert_remote_message(
             account,
             merged,
             receipt.inbound_delivery_id,
             "imported",
             now
           ) do
      :ok
    end
  end

  defp validate_raw_size(raw) when is_binary(raw) do
    max_bytes = Application.get_env(:manifold_mail, :max_raw_bytes, 25 * 1024 * 1024)

    if byte_size(raw) <= max_bytes do
      :ok
    else
      {:error,
       Error.new(
         :permanent,
         :provider_message_too_large,
         "provider raw message exceeds the configured import limit"
       )}
    end
  end

  defp merge_remote_state(message, raw) do
    labels = if message.labels == [], do: raw.labels, else: message.labels

    %ProviderMessage{
      message
      | thread_id: message.thread_id || raw.thread_id,
        received_at: message.received_at || raw.received_at,
        folder_id: message.folder_id || raw.folder_id,
        folder_kind: message.folder_kind || raw.folder_kind || folder_kind(labels),
        labels: labels,
        read?: if(message.labels == [], do: raw.read?, else: message.read?),
        starred?: if(message.labels == [], do: raw.starred?, else: message.starred?)
    }
  end

  defp folder_kind(labels) do
    cond do
      "TRASH" in labels -> "trash"
      "INBOX" in labels -> "inbox"
      "SENT" in labels -> "archive"
      "DRAFT" in labels -> "archive"
      true -> "archive"
    end
  end

  defp external_source(account, storage_domain_id, message, raw, now) do
    %ExternalSource{
      provider: account.provider,
      account_id: account.id,
      external_message_id: message.id,
      mailbox_id: account.mailbox_id,
      storage_domain_id: storage_domain_id,
      recipient_address: account.email_address,
      received_at: message.received_at || raw.received_at || now,
      ingest_id: deterministic_ingest_id(account, message.id)
    }
  end

  defp deterministic_ingest_id(account, message_id) do
    digest =
      :crypto.hash(
        :sha256,
        account.provider <> <<0>> <> account.id <> <<0>> <> message_id
      )
      |> Base.encode16(case: :lower)

    "connector-" <> digest
  end

  defp upsert_remote_message(account, message, delivery_id, state, now) do
    Repo.transaction(fn ->
      existing =
        RemoteMessage
        |> where(
          [remote],
          remote.external_account_id == ^account.id and
            remote.provider_message_id == ^message.id
        )
        |> lock("FOR UPDATE")
        |> Repo.one()

      delivery_id = delivery_id || (existing && existing.inbound_delivery_id)

      attrs = %{
        external_account_id: account.id,
        provider_message_id: message.id,
        provider_thread_id: message.thread_id,
        inbound_delivery_id: delivery_id,
        provider_received_at: message.received_at,
        remote_folder_id: message.folder_id,
        remote_folder_kind: message.folder_kind || folder_kind(message.labels),
        remote_labels: Enum.sort(message.labels),
        remote_read: message.read?,
        remote_starred: message.starred?,
        remote_deleted: message.deleted?,
        state: state,
        last_error_class: nil,
        last_error_code: nil,
        last_error_message: nil,
        synced_at: now
      }

      remote =
        case existing do
          nil ->
            %RemoteMessage{}
            |> RemoteMessage.changeset(attrs)
            |> Repo.insert!()

          remote ->
            remote
            |> RemoteMessage.changeset(attrs)
            |> Repo.update!()
        end

      if is_binary(remote.inbound_delivery_id) do
        ensure_remote_state_job(remote.id)
      end

      remote
    end)
    |> case do
      {:ok, _message} -> :ok
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp checkpoint(account, cursor, page, now) do
    Repo.transaction(fn ->
      locked_cursor =
        SyncCursor
        |> where([stored], stored.id == ^cursor.id)
        |> lock("FOR UPDATE")
        |> Repo.one!()

      unless same_cursor_position?(locked_cursor, cursor) do
        Repo.rollback(
          Error.new(:temporary, :cursor_changed, "connector cursor changed concurrently")
        )
      end

      transitioned_from_initial? =
        cursor.phase in ["initial", "bootstrap"] and page.cursor.phase == "incremental"

      completed_at =
        if is_nil(page.cursor.page_cursor) and not transitioned_from_initial?,
          do: now,
          else: nil

      locked_cursor
      |> SyncCursor.changeset(%{
        phase: page.cursor.phase,
        bootstrap_cursor: page.cursor.bootstrap_cursor,
        page_cursor: page.cursor.page_cursor,
        committed_cursor: page.cursor.committed_cursor,
        metadata: page.cursor.metadata,
        last_completed_at: completed_at
      })
      |> Repo.update!()

      insert_discovered_cursors(account.id, page.discovered_cursors, now)

      more? =
        SyncCursor
        |> where([stored], stored.external_account_id == ^account.id)
        |> where([stored], not is_nil(stored.page_cursor) or is_nil(stored.last_completed_at))
        |> Repo.exists?()

      account
      |> ExternalAccount.changeset(%{
        status: if(more?, do: "syncing", else: "connected"),
        last_synced_at: if(more?, do: account.last_synced_at, else: now),
        last_error_class: nil,
        last_error_code: nil,
        last_error_message: nil
      })
      |> Repo.update!()

      ConnectorEvent.changeset(%ConnectorEvent{}, %{
        external_account_id: account.id,
        event_type: "page_synchronized",
        metadata: %{scope: cursor.scope, message_count: length(page.messages)},
        occurred_at: now
      })
      |> Repo.insert!()

      more?
    end)
  end

  defp insert_discovered_cursors(_account_id, [], _now), do: :ok

  defp insert_discovered_cursors(account_id, cursors, now) do
    {removed, active} = Enum.split_with(cursors, &(&1.phase == "removed"))

    removed_scopes = Enum.map(removed, & &1.scope)

    if removed_scopes != [] do
      SyncCursor
      |> where(
        [cursor],
        cursor.external_account_id == ^account_id and cursor.scope in ^removed_scopes
      )
      |> Repo.delete_all()
    end

    rows =
      Enum.map(active, fn cursor ->
        %{
          id: Ecto.UUID.generate(),
          external_account_id: account_id,
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

    Repo.insert_all(SyncCursor, rows,
      on_conflict: :nothing,
      conflict_target: [:external_account_id, :scope]
    )

    :ok
  end

  defp same_cursor_position?(left, right) do
    Enum.all?([:phase, :bootstrap_cursor, :page_cursor, :committed_cursor, :metadata], fn field ->
      Map.get(left, field) == Map.get(right, field)
    end)
  end

  defp ensure_remote_state_job(remote_message_id) do
    existing =
      Oban.Job
      |> where([job], job.worker == ^inspect(ApplyRemoteState))
      |> where([job], job.state in ~w(available scheduled executing retryable suspended))
      |> where(
        [job],
        fragment("?->>'remote_message_id' = ?", job.args, ^remote_message_id)
      )
      |> order_by([job], asc: job.id)
      |> limit(1)
      |> Repo.one()

    existing ||
      remote_message_id
      |> then(&ApplyRemoteState.new(%{"remote_message_id" => &1}))
      |> Repo.insert!()
  end

  defp collapse_messages(messages) do
    messages
    |> Enum.reduce(%{}, fn %ProviderMessage{id: id} = message, acc ->
      Map.update(acc, id, message, &prefer_message(&1, message))
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  defp prefer_message(%ProviderMessage{tombstone_kind: :membership}, current), do: current
  defp prefer_message(existing, %ProviderMessage{tombstone_kind: :membership}), do: existing
  defp prefer_message(_existing, current), do: current

  defp provider_cursor(cursor) do
    %ProviderCursor{
      scope: cursor.scope,
      phase: cursor.phase,
      bootstrap_cursor: cursor.bootstrap_cursor,
      page_cursor: cursor.page_cursor,
      committed_cursor: cursor.committed_cursor,
      metadata: cursor.metadata
    }
  end

  defp runtime("imap") do
    adapters = Application.get_env(:manifold_connectors, :adapters, [])
    adapter = Keyword.get(adapters, :imap) || Manifold.Connectors.Provider.IMAP
    {:ok, adapter, []}
  end

  defp runtime(provider) when provider in ["gmail", "microsoft"] do
    key = String.to_existing_atom(provider)
    adapters = Application.get_env(:manifold_connectors, :adapters, [])
    providers = Application.get_env(:manifold_connectors, :providers, [])

    adapter =
      Keyword.get(adapters, key) ||
        case provider do
          "gmail" -> Manifold.Connectors.Provider.Gmail
          "microsoft" -> Manifold.Connectors.Provider.MicrosoftGraph
        end

    case Keyword.get(providers, key) do
      config when is_list(config) ->
        {:ok, adapter, config}

      _missing ->
        {:error, Error.new(:permanent, :provider_not_configured, "provider is not configured")}
    end
  end

  defp runtime(_provider) do
    {:error, Error.new(:permanent, :unsupported_provider, "provider is not supported")}
  end

  defp enrich_runtime_config(%ExternalAccount{provider: "imap"} = account, config) do
    case Repo.get_by(ImapSettings, external_account_id: account.id) do
      %ImapSettings{} = settings ->
        transport =
          Application.get_env(
            :manifold_connectors,
            :imap_transport,
            Manifold.Connectors.IMAP.Client
          )

        fake = Application.get_env(:manifold_connectors, :imap_fake, %{})

        {:ok,
         Keyword.merge(config,
           host: settings.host,
           port: settings.port,
           tls_mode: settings.tls_mode,
           username: settings.username,
           mailbox_path: settings.mailbox_path,
           account_id: account.id,
           transport: transport,
           fake: if(is_map(fake), do: fake, else: %{})
         )}

      nil ->
        {:error,
         Error.new(:permanent, :imap_settings_missing, "IMAP settings are missing for account")}
    end
  end

  defp enrich_runtime_config(_account, config), do: {:ok, config}

  defp handle_provider_error(account_id, %ProviderError{} = error, now) do
    status = if error.class == :reconnect, do: "reconnect_required", else: "failed"
    record_provider_failure(account_id, status, error, now)

    case error.class do
      :temporary -> {:snooze, error.retry_after_seconds || @default_retry_seconds}
      :reconnect -> {:cancel, :reconnect_required}
      :permanent -> {:cancel, error.code}
    end
  end

  defp handle_cursor_provider_error(
         account_id,
         %SyncCursor{scope: "folder:" <> _folder_id} = cursor,
         %ProviderError{code: :not_found},
         now
       ) do
    Repo.transaction(fn ->
      Repo.delete_all(from(stored in SyncCursor, where: stored.id == ^cursor.id))

      more? =
        SyncCursor
        |> where([stored], stored.external_account_id == ^account_id)
        |> Repo.exists?()

      case Repo.get(ExternalAccount, account_id) do
        %ExternalAccount{} = account ->
          account
          |> ExternalAccount.changeset(%{
            status: if(more?, do: "syncing", else: "connected"),
            last_synced_at: if(more?, do: account.last_synced_at, else: now),
            last_error_class: nil,
            last_error_code: nil,
            last_error_message: nil
          })
          |> Repo.update!()

          ConnectorEvent.changeset(%ConnectorEvent{}, %{
            external_account_id: account_id,
            event_type: "folder_cursor_removed",
            metadata: %{scope: cursor.scope},
            occurred_at: now
          })
          |> Repo.insert!()

        nil ->
          :ok
      end

      more?
    end)
    |> case do
      {:ok, true} -> {:snooze, 1}
      {:ok, false} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_cursor_provider_error(account_id, _cursor, error, now),
    do: handle_provider_error(account_id, error, now)

  defp handle_core_error(
         _account_id,
         %Error{class: :permanent, reason: reason},
         _now
       )
       when reason in [:account_disconnected, :sync_disabled, :account_not_found] do
    {:cancel, reason}
  end

  defp handle_core_error(account_id, %Error{class: :permanent} = error, now) do
    record_failure(account_id, error.class, error.reason, error.message, now)
    {:cancel, error.reason}
  end

  defp handle_core_error(account_id, %Error{} = error, now) do
    record_failure(account_id, error.class, error.reason, error.message, now)
    {:error, error}
  end

  defp record_provider_failure(account_id, status, error, now) do
    Repo.transaction(fn ->
      case Repo.get(ExternalAccount, account_id) do
        nil ->
          :ok

        account ->
          account
          |> ExternalAccount.changeset(%{
            status: status,
            last_error_class: Atom.to_string(error.class),
            last_error_code: Atom.to_string(error.code),
            last_error_message: error.message
          })
          |> Repo.update!()

          insert_failure_event(account_id, error.class, error.code, now)
      end
    end)
  end

  defp record_failure(account_id, class, code, message, now) do
    provider_error = %ProviderError{
      class: if(class == :temporary, do: :temporary, else: :permanent),
      code: code,
      message: message
    }

    record_provider_failure(account_id, "failed", provider_error, now)
  end

  defp insert_failure_event(account_id, class, code, now) do
    ConnectorEvent.changeset(%ConnectorEvent{}, %{
      external_account_id: account_id,
      event_type: "sync_failed",
      metadata: %{class: Atom.to_string(class), code: Atom.to_string(code)},
      occurred_at: now
    })
    |> Repo.insert!()
  end

  defp credential_context(account_id, kind), do: "credential:#{account_id}:#{kind}"
  defp provider_opts(opts), do: Keyword.get(opts, :provider_opts, [])
  defp ingest_opts(opts), do: Keyword.take(opts, [:spool_opts])

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, Error.new(:temporary, point, "injected connector sync fault")}
    else
      :ok
    end
  end
end

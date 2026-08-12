defmodule Manifold.Connectors.MicrosoftFolderMapping do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Connectors.Provider.FolderMapping
  alias Manifold.Connectors.RemoteStateJobs

  alias Manifold.Connectors.Schema.{
    OAuthAuthorization,
    ReceiveMethod,
    RemoteMessage,
    SyncCursor
  }

  alias Manifold.Core.Error
  alias Manifold.Repo

  @mapping_version 1
  @telemetry_event [:manifold, :connectors, :microsoft, :folder_mapping, :stop]
  @telemetry_forbidden_fragments ~w(token password authorization_code raw_message)
  @telemetry_code_pattern ~r/\A[a-z0-9_.:-]{1,128}\z/

  @spec ensure_current(
          ReceiveMethod.t(),
          SyncCursor.t(),
          String.t(),
          module(),
          keyword(),
          keyword()
        ) :: {:ok, SyncCursor.t()} | {:error, ProviderError.t() | Error.t()}
  def ensure_current(
        %ReceiveMethod{} = receive_method,
        %SyncCursor{} = selected_cursor,
        access_token,
        adapter,
        config,
        opts
      ) do
    start = System.monotonic_time()

    try do
      result =
        with {:ok, cursors} <- load_cursors(receive_method.id),
             {:ok, folders_cursor} <- folders_cursor(cursors) do
          if current?(folders_cursor, cursors) do
            {:ok, selected_cursor, 0, 0, :current}
          else
            with {:ok, snapshot} <-
                   lifecycle_snapshot(receive_method, selected_cursor.id, cursors),
                 {:ok, %FolderMapping{version: @mapping_version} = mapping} <-
                   adapter.resolve_folder_mapping(access_token, config, opts) do
              reconcile(receive_method, selected_cursor.id, mapping, snapshot)
            else
              {:ok, %FolderMapping{}} -> {:error, invalid_mapping_error()}
              {:error, reason} -> {:error, reason}
            end
          end
        end

      emit_stop(receive_method, start, result)
      public_result(result)
    rescue
      DBConnection.ConnectionError ->
        error = database_error()
        emit_stop(receive_method, start, {:error, error})
        {:error, error}

      _error in Postgrex.Error ->
        error = database_error()
        emit_stop(receive_method, start, {:error, error})
        {:error, error}
    end
  end

  @spec invalidate(Ecto.UUID.t()) :: :ok | {:error, Error.t()}
  def invalidate(receive_method_id) do
    Repo.transaction(fn ->
      receive_method_id
      |> lock_cursors()
      |> Enum.each(fn cursor ->
        metadata =
          cursor.metadata
          |> Map.delete("folder_mapping_version")
          |> Map.put("folder_mapping_refresh_required", true)

        if metadata != cursor.metadata do
          cursor
          |> SyncCursor.changeset(%{metadata: metadata})
          |> Repo.update!()
        end
      end)

      :ok
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, %Error{} = error} -> {:error, error}
      {:error, _reason} -> {:error, database_error()}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error()}
    _error in Postgrex.Error -> {:error, database_error()}
  end

  defp reconcile(receive_method, selected_cursor_id, mapping, snapshot) do
    Repo.transaction(fn ->
      authorization = lock_authorization(snapshot.authorization.id)
      cursors = lock_cursors(receive_method.id)

      with {:ok, folders_cursor} <- folders_cursor(cursors),
           {:ok, _selected_cursor} <- selected_cursor(cursors, selected_cursor_id),
           {:ok, locked_method} <- lock_active_method(receive_method.id),
           :ok <- validate_lifecycle_snapshot(authorization, locked_method, cursors, snapshot) do
        if current?(folders_cursor, cursors) do
          {Repo.get!(SyncCursor, selected_cursor_id), 0, 0, :current}
        else
          cursor_count = update_cursor_metadata(cursors, folders_cursor.id, mapping)
          changed_message_count = update_remote_messages(receive_method.id, mapping.kinds_by_id)

          {Repo.get!(SyncCursor, selected_cursor_id), cursor_count, changed_message_count,
           :repaired}
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {cursor, cursor_count, changed_message_count, outcome}} ->
        {:ok, cursor, cursor_count, changed_message_count, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_cursors(receive_method_id) do
    cursors =
      SyncCursor
      |> where([cursor], cursor.external_account_id == ^receive_method_id)
      |> order_by([cursor], asc: cursor.id)
      |> Repo.all()

    {:ok, cursors}
  end

  defp lifecycle_snapshot(receive_method, selected_cursor_id, cursors) do
    with {:ok, _selected_cursor} <- selected_cursor(cursors, selected_cursor_id),
         {:ok, method} <- active_method(receive_method.id),
         :ok <- validate_input_method(receive_method, method),
         {:ok, authorization} <- active_authorization(method) do
      {:ok,
       %{
         authorization: authorization_snapshot(authorization),
         method: method_snapshot(method),
         cursors: Enum.map(cursors, &cursor_snapshot/1)
       }}
    end
  end

  defp lock_cursors(receive_method_id) do
    SyncCursor
    |> where([cursor], cursor.external_account_id == ^receive_method_id)
    |> order_by([cursor], asc: cursor.id)
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  defp lock_authorization(authorization_id) do
    OAuthAuthorization
    |> where([authorization], authorization.id == ^authorization_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp folders_cursor(cursors) do
    case Enum.filter(cursors, &(&1.scope == "folders")) do
      [cursor] -> {:ok, cursor}
      _missing_or_duplicate -> {:error, folders_cursor_error()}
    end
  end

  defp selected_cursor(cursors, selected_cursor_id) do
    case Enum.find(cursors, &(&1.id == selected_cursor_id)) do
      %SyncCursor{} = cursor -> {:ok, cursor}
      nil -> {:error, lifecycle_changed_error()}
    end
  end

  defp lock_active_method(receive_method_id) do
    ReceiveMethod
    |> where([receive_method], receive_method.id == ^receive_method_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> validate_active_method()
  end

  defp active_method(receive_method_id) do
    receive_method_id
    |> then(&Repo.get(ReceiveMethod, &1))
    |> validate_active_method()
  end

  defp validate_active_method(method) do
    case method do
      %ReceiveMethod{
        kind: "microsoft",
        enabled: true,
        sync_enabled: true,
        status: status
      } = method
      when status in ["connected", "syncing"] ->
        {:ok, method}

      _changed_or_missing ->
        {:error, lifecycle_changed_error()}
    end
  end

  defp active_authorization(%ReceiveMethod{oauth_authorization_id: authorization_id} = method)
       when is_binary(authorization_id) do
    case Repo.get(OAuthAuthorization, authorization_id) do
      %OAuthAuthorization{
        id: ^authorization_id,
        account_id: account_id,
        provider: "microsoft",
        status: "connected"
      } = authorization
      when account_id == method.account_id ->
        {:ok, authorization}

      _changed_or_missing ->
        {:error, lifecycle_changed_error()}
    end
  end

  defp active_authorization(_method), do: {:error, lifecycle_changed_error()}

  defp validate_input_method(receive_method, current_method) do
    if method_snapshot(receive_method) == method_snapshot(current_method) do
      :ok
    else
      {:error, lifecycle_changed_error()}
    end
  end

  defp validate_lifecycle_snapshot(authorization, method, cursors, snapshot) do
    if authorization_snapshot(authorization) == snapshot.authorization and
         method_snapshot(method) == snapshot.method and
         Enum.map(cursors, &cursor_snapshot/1) == snapshot.cursors do
      :ok
    else
      {:error, lifecycle_changed_error()}
    end
  end

  defp authorization_snapshot(%OAuthAuthorization{} = authorization) do
    Map.take(authorization, [
      :id,
      :account_id,
      :provider,
      :provider_subject_id,
      :email_address,
      :status,
      :lock_version
    ])
  end

  defp authorization_snapshot(_authorization), do: nil

  defp method_snapshot(%ReceiveMethod{} = method) do
    Map.take(method, [
      :id,
      :account_id,
      :oauth_authorization_id,
      :kind,
      :provider_account_id,
      :email_address,
      :status,
      :enabled,
      :sync_enabled,
      :lock_version
    ])
  end

  defp cursor_snapshot(%SyncCursor{} = cursor) do
    Map.take(cursor, [
      :id,
      :external_account_id,
      :scope,
      :metadata,
      :generation,
      :lock_version
    ])
  end

  defp current?(folders_cursor, cursors) do
    folders_cursor.metadata["folder_mapping_version"] == @mapping_version and
      Enum.all?(cursors, fn cursor ->
        cursor.metadata["folder_mapping_refresh_required"] != true
      end)
  end

  defp update_cursor_metadata(cursors, folders_cursor_id, mapping) do
    Enum.count(cursors, fn cursor ->
      metadata = mapped_cursor_metadata(cursor, folders_cursor_id, mapping)

      if metadata == cursor.metadata do
        false
      else
        cursor
        |> SyncCursor.changeset(%{metadata: metadata})
        |> Repo.update!()

        true
      end
    end)
  end

  defp mapped_cursor_metadata(cursor, folders_cursor_id, mapping)
       when cursor.id == folders_cursor_id do
    cursor.metadata
    |> Map.put("folder_mapping_version", @mapping_version)
    |> Map.put("folder_kinds_by_id", mapping.kinds_by_id)
    |> Map.delete("folder_mapping_refresh_required")
  end

  defp mapped_cursor_metadata(%SyncCursor{scope: "folder:" <> folder_id} = cursor, _id, mapping) do
    cursor.metadata
    |> Map.put("folder_mapping_version", @mapping_version)
    |> Map.put("folder_kind", Map.get(mapping.kinds_by_id, folder_id, "archive"))
    |> Map.delete("folder_mapping_refresh_required")
  end

  defp mapped_cursor_metadata(cursor, _folders_cursor_id, _mapping) do
    Map.delete(cursor.metadata, "folder_mapping_refresh_required")
  end

  defp update_remote_messages(receive_method_id, kinds_by_id) do
    RemoteMessage
    |> where([remote], remote.external_account_id == ^receive_method_id)
    |> order_by([remote], asc: remote.id)
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.count(fn remote ->
      folder_kind = Map.get(kinds_by_id, remote.remote_folder_id, "archive")

      if folder_kind == remote.remote_folder_kind do
        false
      else
        updated =
          remote
          |> RemoteMessage.changeset(%{remote_folder_kind: folder_kind})
          |> Repo.update!()

        if updated.state == "imported" and is_binary(updated.inbound_delivery_id) do
          RemoteStateJobs.ensure(updated.id)
        end

        true
      end
    end)
  end

  defp public_result({:ok, cursor, _cursor_count, _changed_message_count, _outcome}),
    do: {:ok, cursor}

  defp public_result({:error, reason}), do: {:error, reason}

  defp emit_stop(receive_method, start, result) do
    {cursor_count, changed_message_count, outcome, error_code} =
      case result do
        {:ok, _cursor, cursor_count, changed_message_count, outcome} ->
          {cursor_count, changed_message_count, outcome, nil}

        {:error, reason} ->
          {0, 0, :error, normalized_error_code(reason)}
      end

    :telemetry.execute(
      @telemetry_event,
      %{
        duration_ms: duration_ms(start),
        cursor_count: cursor_count,
        changed_message_count: changed_message_count
      },
      %{
        account_id: receive_method.account_id,
        method_id: receive_method.id,
        provider: "microsoft",
        outcome: outcome,
        error_code: error_code
      }
    )
  end

  defp normalized_error_code(%ProviderError{code: code}), do: telemetry_error_code(code)
  defp normalized_error_code(%Error{reason: reason}), do: telemetry_error_code(reason)
  defp normalized_error_code(_reason), do: :folder_mapping_failed

  defp telemetry_error_code(code) when is_atom(code) do
    if safe_telemetry_code?(Atom.to_string(code)), do: code, else: :folder_mapping_failed
  end

  defp telemetry_error_code(code) when is_binary(code) do
    if safe_telemetry_code?(code), do: code, else: "folder_mapping_failed"
  end

  defp telemetry_error_code(_code), do: :folder_mapping_failed

  defp safe_telemetry_code?(code) do
    downcased = String.downcase(code)

    Regex.match?(@telemetry_code_pattern, downcased) and
      not Enum.any?(@telemetry_forbidden_fragments, &String.contains?(downcased, &1))
  end

  defp duration_ms(start) do
    System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
  end

  defp folders_cursor_error do
    Error.new(
      :permanent,
      :folder_cursor_missing,
      "Microsoft folder discovery cursor is missing"
    )
  end

  defp lifecycle_changed_error do
    Error.new(
      :temporary,
      :connector_lifecycle_changed,
      "connector lifecycle changed during folder reconciliation"
    )
  end

  defp invalid_mapping_error do
    Error.new(
      :permanent,
      :invalid_folder_mapping,
      "Microsoft folder mapping is invalid"
    )
  end

  defp database_error do
    Error.new(
      :temporary,
      :database_unavailable,
      "Microsoft folder mapping could not be persisted"
    )
  end
end

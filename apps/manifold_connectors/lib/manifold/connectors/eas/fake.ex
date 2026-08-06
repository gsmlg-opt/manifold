defmodule Manifold.Connectors.EAS.Fake do
  @moduledoc false

  @behaviour Manifold.Connectors.EAS.Transport

  alias Manifold.Connectors.Provider.Error

  @impl true
  def connect(settings) when is_map(settings) do
    bump_connect_count(settings)
    connect_start = System.monotonic_time()
    base_meta = base_meta(settings)

    emit(
      [:manifold, :connectors, :eas, :connect, :stop],
      connect_start,
      base_meta,
      :ok,
      settings
    )

    auth_start = System.monotonic_time()
    expected = Map.get(settings, :password_expected)

    if is_binary(expected) and settings.password != expected do
      error = %Error{
        class: :reconnect,
        code: :auth_failed,
        message: "EAS authentication failed"
      }

      emit(
        [:manifold, :connectors, :eas, :auth, :stop],
        auth_start,
        auth_meta(settings),
        error,
        settings
      )

      {:error, error}
    else
      emit(
        [:manifold, :connectors, :eas, :auth, :stop],
        auth_start,
        auth_meta(settings),
        :ok,
        settings
      )

      {:ok, pid} =
        Agent.start_link(fn ->
          %{
            settings: settings,
            policy_key: Map.get(settings, :policy_key) || "0",
            folder_sync_key: "0",
            sync_key: "0"
          }
        end)

      {:ok, pid}
    end
  end

  @impl true
  def provision(conn) when is_pid(conn) do
    start = System.monotonic_time()
    settings = Agent.get(conn, & &1.settings)
    policy_key = Map.get(settings, :policy_key_result, "12345")
    Agent.update(conn, &%{&1 | policy_key: policy_key})

    emit(
      [:manifold, :connectors, :eas, :provision, :stop],
      start,
      Map.put(base_meta(settings), :policy_key, policy_key),
      :ok,
      settings
    )

    {:ok, conn, %{policy_key: policy_key}}
  end

  @impl true
  def folder_sync(conn, _sync_key) when is_pid(conn) do
    settings = Agent.get(conn, & &1.settings)

    folders =
      Map.get(settings, :folders, [
        %{server_id: "1", display_name: "Inbox", type: "2", parent_id: "0"}
      ])

    Agent.update(conn, &%{&1 | folder_sync_key: "1"})
    {:ok, conn, %{sync_key: "1", folders: folders}}
  end

  @impl true
  def sync(conn, opts) when is_pid(conn) and is_map(opts) do
    settings = Agent.get(conn, & &1.settings)
    sync_key = Map.get(opts, :sync_key, "0")
    window_size = Map.get(opts, :window_size, 25)
    messages = Map.get(settings, :messages, [])

    {adds, more?} =
      if sync_key == "0" do
        {[], messages != []}
      else
        last_id = Map.get(settings, :last_synced_id)

        pending =
          messages
          |> Enum.filter(fn entry ->
            id = message_id(entry)
            is_nil(last_id) or id > last_id
          end)
          |> Enum.sort_by(&message_id/1)

        page = Enum.take(pending, window_size)
        adds = Enum.map(page, &sync_item/1)

        if page != [] do
          last_id = message_id(List.last(page))

          Agent.update(conn, fn state ->
            put_in(state, [:settings, :last_synced_id], last_id)
          end)
        end

        {adds, length(pending) > length(page)}
      end

    changes =
      if sync_key == "0" do
        []
      else
        settings
        |> Map.get(:pending_changes, [])
        |> Enum.map(fn
          {id, read?} when is_boolean(read?) -> %{server_id: to_string(id), read?: read?}
          %{server_id: id, read?: read?} -> %{server_id: to_string(id), read?: read?}
        end)
      end

    if changes != [] do
      Agent.update(conn, fn state ->
        put_in(state, [:settings, :pending_changes], [])
      end)
    end

    new_key =
      case Integer.parse(to_string(sync_key)) do
        {n, ""} -> Integer.to_string(n + 1)
        _ -> "1"
      end

    Agent.update(conn, &%{&1 | sync_key: new_key})

    {:ok, conn,
     %{
       sync_key: new_key,
       adds: adds,
       changes: changes,
       deletes: [],
       more_available?: more?
     }}
  end

  @impl true
  def change_read(conn, opts) when is_pid(conn) and is_map(opts) do
    server_id = Map.fetch!(opts, :server_id)
    read? = Map.fetch!(opts, :read?)
    sync_key = Map.get(opts, :sync_key, "1")
    settings = Agent.get(conn, & &1.settings)

    case Map.get(settings, :change_log) do
      log when is_pid(log) ->
        Agent.update(log, &[{server_id, read?} | &1])

      _ ->
        :ok
    end

    Agent.update(conn, fn state ->
      messages =
        Enum.map(Map.get(state.settings, :messages, []), fn
          {id, raw} = msg ->
            if to_string(id) == server_id, do: {id, raw, %{read?: read?}}, else: msg

          {id, raw, meta} = msg when is_map(meta) ->
            if to_string(id) == server_id, do: {id, raw, Map.put(meta, :read?, read?)}, else: msg

          other ->
            other
        end)

      state
      |> put_in([:settings, :messages], messages)
      |> Map.update!(:sync_key, fn _ ->
        case Integer.parse(to_string(sync_key)) do
          {n, ""} -> Integer.to_string(n + 1)
          _ -> "2"
        end
      end)
    end)

    new_key = Agent.get(conn, & &1.sync_key)
    {:ok, conn, %{sync_key: new_key}}
  end

  @impl true
  def fetch_mime(conn, _collection_id, server_id) when is_pid(conn) and is_binary(server_id) do
    messages = Agent.get(conn, &Map.get(&1.settings, :messages, []))

    case Enum.find(messages, fn entry -> to_string(message_id(entry)) == server_id end) do
      {_id, raw} ->
        {:ok, raw}

      {_id, raw, _meta} ->
        {:ok, raw}

      nil ->
        {:error,
         %Error{class: :permanent, code: :message_not_found, message: "EAS message not found"}}
    end
  end

  @impl true
  def close(conn) when is_pid(conn) do
    Agent.stop(conn)
    :ok
  end

  defp message_id({id, _raw}), do: id
  defp message_id({id, _raw, _meta}), do: id

  defp sync_item({id, _raw}), do: %{server_id: to_string(id), read?: false, received_at: nil}

  defp sync_item({id, _raw, meta}) when is_map(meta),
    do: %{
      server_id: to_string(id),
      read?: Map.get(meta, :read?, false),
      received_at: Map.get(meta, :received_at)
    }

  defp bump_connect_count(settings) do
    case Map.get(settings, :connect_count) do
      counter when is_pid(counter) -> Agent.update(counter, &(&1 + 1))
      _ -> :ok
    end
  end

  defp base_meta(settings) do
    %{
      host: Map.get(settings, :host),
      port: Map.get(settings, :port),
      provider: "eas"
    }
    |> maybe_put(:account_id, Map.get(settings, :account_id))
  end

  defp auth_meta(settings) do
    settings
    |> base_meta()
    |> maybe_put(:username, Map.get(settings, :username))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit(event, start, meta, :ok, settings) do
    if Map.get(settings, :emit_activity, true) != false do
      :telemetry.execute(
        event,
        %{duration_ms: now_ms(start)},
        Map.put(meta, :result, :ok)
      )
    end
  end

  defp emit(event, start, meta, %Error{} = error, settings) do
    if Map.get(settings, :emit_activity, true) != false do
      :telemetry.execute(
        event,
        %{duration_ms: now_ms(start)},
        meta
        |> Map.put(:result, :error)
        |> Map.put(:error_code, error.code)
        |> Map.put(:error_message, error.message)
      )
    end
  end

  defp now_ms(start) do
    System.convert_time_unit(System.monotonic_time() - start, :native, :millisecond)
  end
end

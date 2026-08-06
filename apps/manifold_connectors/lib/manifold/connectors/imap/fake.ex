defmodule Manifold.Connectors.IMAP.Fake do
  @moduledoc false

  @behaviour Manifold.Connectors.IMAP.Transport

  alias Manifold.Connectors.Provider.Error

  @impl true
  def connect(settings) when is_map(settings) do
    bump_connect_count(settings)
    connect_start = System.monotonic_time()
    base_meta = base_meta(settings)

    emit(
      [:manifold, :connectors, :imap, :connect, :stop],
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
        message: "IMAP authentication failed"
      }

      emit(
        [:manifold, :connectors, :imap, :auth, :stop],
        auth_start,
        auth_meta(settings),
        error,
        settings
      )

      {:error, error}
    else
      emit(
        [:manifold, :connectors, :imap, :auth, :stop],
        auth_start,
        auth_meta(settings),
        :ok,
        settings
      )

      {:ok, pid} = Agent.start_link(fn -> %{settings: settings, selected: nil} end)
      {:ok, pid}
    end
  end

  @impl true
  def select(conn, mailbox_path) when is_pid(conn) and is_binary(mailbox_path) do
    start = System.monotonic_time()
    settings = Agent.get(conn, & &1.settings)
    Agent.update(conn, &%{&1 | selected: mailbox_path})
    uidvalidity = Map.get(settings, :uidvalidity, 1)
    uidnext = Map.get(settings, :uidnext)

    meta =
      settings
      |> base_meta()
      |> Map.merge(%{mailbox_path: mailbox_path, uidvalidity: uidvalidity})

    emit([:manifold, :connectors, :imap, :select, :stop], start, meta, :ok, settings)
    {:ok, %{uidvalidity: uidvalidity, uidnext: uidnext}}
  end

  @impl true
  def uid_search(conn, query) when is_pid(conn) and is_binary(query) do
    messages = Agent.get(conn, &Map.get(&1.settings, :messages, []))

    uids =
      case String.upcase(String.trim(query)) do
        "UNSEEN" ->
          messages
          |> Enum.map(&normalize_message/1)
          |> Enum.reject(fn {_uid, _raw, flags, _received_at} ->
            Enum.any?(flags, &(String.downcase(&1) == "\\seen"))
          end)
          |> Enum.map(&elem(&1, 0))

        _ ->
          Enum.map(messages, &message_uid/1)
      end

    {:ok, uids}
  end

  @impl true
  def uid_fetch_flags(conn, uids) when is_pid(conn) and is_list(uids) do
    messages = Agent.get(conn, &Map.get(&1.settings, :messages, []))

    meta_by_uid =
      Enum.reduce(uids, %{}, fn uid, acc ->
        case find_message(messages, uid) do
          {_uid, _raw, flags, received_at} ->
            Map.put(acc, uid, %{flags: flags, received_at: received_at})

          nil ->
            acc
        end
      end)

    {:ok, meta_by_uid}
  end

  @impl true
  def uid_store_flags(conn, uid, op, flags)
      when is_pid(conn) and is_integer(uid) and op in [:add, :remove] and is_list(flags) do
    settings = Agent.get(conn, & &1.settings)

    case Map.get(settings, :store_log) do
      log when is_pid(log) -> Agent.update(log, &[{uid, op, flags} | &1])
      _ -> :ok
    end

    Agent.update(conn, fn state ->
      messages =
        Enum.map(Map.get(state.settings, :messages, []), fn message ->
          case normalize_message(message) do
            {^uid, raw, current_flags, received_at} ->
              updated_flags = apply_flag_op(current_flags, op, flags)
              {uid, raw, updated_flags, received_at}

            other ->
              other
          end
        end)

      %{state | settings: Map.put(state.settings, :messages, messages)}
    end)

    :ok
  end

  @impl true
  def uid_fetch_rfc822(conn, uid) when is_pid(conn) and is_integer(uid) do
    messages = Agent.get(conn, &Map.get(&1.settings, :messages, []))

    case find_message(messages, uid) do
      {^uid, raw, _flags, _received_at} ->
        {:ok, raw}

      nil ->
        {:error,
         %Error{class: :permanent, code: :message_not_found, message: "IMAP message not found"}}
    end
  end

  @impl true
  def logout(conn) when is_pid(conn) do
    Agent.stop(conn)
    :ok
  end

  defp message_uid(message) do
    {uid, _raw, _flags, _received_at} = normalize_message(message)
    uid
  end

  defp find_message(messages, uid) do
    Enum.find_value(messages, fn message ->
      case normalize_message(message) do
        {^uid, raw, flags, received_at} -> {uid, raw, flags, received_at}
        _ -> nil
      end
    end)
  end

  defp normalize_message({uid, raw}), do: {uid, raw, [], nil}

  defp normalize_message({uid, raw, flags}) when is_list(flags), do: {uid, raw, flags, nil}

  defp normalize_message({uid, raw, flags, received_at}) when is_list(flags),
    do: {uid, raw, flags, received_at}

  defp normalize_message(%{uid: uid, raw: raw} = message) do
    {uid, raw, Map.get(message, :flags, []), Map.get(message, :received_at)}
  end

  defp apply_flag_op(current_flags, :add, flags) do
    Enum.uniq(current_flags ++ flags)
  end

  defp apply_flag_op(current_flags, :remove, flags) do
    remove = MapSet.new(Enum.map(flags, &String.downcase/1))

    Enum.reject(current_flags, fn flag ->
      MapSet.member?(remove, String.downcase(flag))
    end)
  end

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
      tls_mode: Map.get(settings, :tls_mode),
      provider: "imap"
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

defmodule Manifold.Connectors.IMAP.Fake do
  @moduledoc false

  @behaviour Manifold.Connectors.IMAP.Transport

  alias Manifold.Connectors.Provider.Error

  @impl true
  def connect(settings) when is_map(settings) do
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
  def uid_search(conn, _query) when is_pid(conn) do
    messages = Agent.get(conn, &Map.get(&1.settings, :messages, []))
    {:ok, Enum.map(messages, fn {uid, _raw} -> uid end)}
  end

  @impl true
  def uid_fetch_rfc822(conn, uid) when is_pid(conn) and is_integer(uid) do
    messages = Agent.get(conn, &Map.get(&1.settings, :messages, []))

    case List.keyfind(messages, uid, 0) do
      {^uid, raw} ->
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

defmodule Manifold.Connectors.IMAP.Fake do
  @moduledoc false

  @behaviour Manifold.Connectors.IMAP.Transport

  alias Manifold.Connectors.Provider.Error

  @impl true
  def connect(settings) when is_map(settings) do
    expected = Map.get(settings, :password_expected)

    if is_binary(expected) and settings.password != expected do
      {:error,
       %Error{
         class: :reconnect,
         code: :auth_failed,
         message: "IMAP authentication failed"
       }}
    else
      {:ok, pid} = Agent.start_link(fn -> %{settings: settings, selected: nil} end)
      {:ok, pid}
    end
  end

  @impl true
  def select(conn, mailbox_path) when is_pid(conn) and is_binary(mailbox_path) do
    Agent.update(conn, &%{&1 | selected: mailbox_path})
    settings = Agent.get(conn, & &1.settings)
    uidvalidity = Map.get(settings, :uidvalidity, 1)
    uidnext = Map.get(settings, :uidnext)

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
end

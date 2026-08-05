defmodule Manifold.Connectors.Provider.IMAP do
  @moduledoc """
  Read-only IMAP INBOX synchronization adapter.

  Auth material is the plaintext mailbox password. Bodies are fetched via
  `fetch_raw/4`; `sync_page/4` only enumerates UIDs.
  """

  @behaviour Manifold.Connectors.Provider

  alias Manifold.Connectors.IMAP.Client

  alias Manifold.Connectors.Provider.{
    Error,
    Identity,
    Page,
    RawMessage,
    RemoteMessage,
    SyncCursor
  }

  @default_page_size 50

  @impl true
  def identity(_password, config, _opts) do
    username = Keyword.fetch!(config, :username)

    {:ok,
     %Identity{
       id: "imap:" <> username,
       email_address: username
     }}
  end

  @impl true
  def initial_cursors(_password, config, _opts) do
    mailbox_path = Keyword.get(config, :mailbox_path, "INBOX")

    {:ok,
     [
       %SyncCursor{
         scope: mailbox_path,
         phase: "bootstrap",
         metadata: %{}
       }
     ]}
  end

  @impl true
  def sync_page(password, %SyncCursor{} = cursor, config, _opts) do
    transport = transport(config)
    mailbox_path = Keyword.get(config, :mailbox_path, cursor.scope || "INBOX")
    page_size = Keyword.get(config, :page_size, @default_page_size)

    with {:ok, conn} <- transport.connect(settings(password, config)),
         {:ok, %{uidvalidity: uidvalidity}} <- transport.select(conn, mailbox_path),
         {:ok, uids} <- transport.uid_search(conn, "ALL") do
      metadata = normalize_metadata(cursor.metadata, uidvalidity)
      last_uid = Map.get(metadata, "last_uid", 0)

      page_uids =
        uids
        |> Enum.filter(&(&1 > last_uid))
        |> Enum.sort()
        |> Enum.take(page_size)

      messages =
        Enum.map(page_uids, fn uid ->
          %RemoteMessage{
            id: remote_id(uidvalidity, uid),
            folder_id: mailbox_path,
            folder_kind: "inbox"
          }
        end)

      new_last_uid =
        case List.last(page_uids) do
          nil -> last_uid
          uid -> uid
        end

      remaining? =
        uids
        |> Enum.filter(&(&1 > new_last_uid))
        |> Enum.any?()

      phase = if remaining?, do: "bootstrap", else: "incremental"

      page = %Page{
        messages: messages,
        cursor: %SyncCursor{
          cursor
          | phase: phase,
            metadata: %{
              "uidvalidity" => uidvalidity,
              "last_uid" => new_last_uid
            }
        }
      }

      transport.logout(conn)
      {:ok, page}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def fetch_raw(password, remote_message_id, config, _opts) do
    transport = transport(config)
    mailbox_path = Keyword.get(config, :mailbox_path, "INBOX")

    with {:ok, uidvalidity, uid} <- parse_remote_id(remote_message_id),
         {:ok, conn} <- transport.connect(settings(password, config)),
         {:ok, %{uidvalidity: selected_uv}} <- transport.select(conn, mailbox_path),
         :ok <- ensure_uidvalidity(uidvalidity, selected_uv),
         {:ok, bytes} <- transport.uid_fetch_rfc822(conn, uid) do
      transport.logout(conn)

      {:ok,
       %RawMessage{
         bytes: bytes,
         folder_id: mailbox_path,
         folder_kind: "inbox"
       }}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp transport(config), do: Keyword.get(config, :transport, Client)

  defp settings(password, config) do
    base = %{
      host: Keyword.fetch!(config, :host),
      port: Keyword.fetch!(config, :port),
      tls_mode: Keyword.fetch!(config, :tls_mode),
      username: Keyword.fetch!(config, :username),
      password: password,
      mailbox_path: Keyword.get(config, :mailbox_path, "INBOX")
    }

    case Keyword.get(config, :fake) do
      %{} = fake -> Map.merge(base, fake)
      _ -> base
    end
  end

  defp normalize_metadata(metadata, uidvalidity) when is_map(metadata) do
    stored = metadata["uidvalidity"] || metadata[:uidvalidity]

    cond do
      is_nil(stored) ->
        %{"uidvalidity" => uidvalidity, "last_uid" => 0}

      stored == uidvalidity ->
        last = metadata["last_uid"] || metadata[:last_uid] || 0
        %{"uidvalidity" => uidvalidity, "last_uid" => last}

      true ->
        %{"uidvalidity" => uidvalidity, "last_uid" => 0}
    end
  end

  defp remote_id(uidvalidity, uid), do: "imap:#{uidvalidity}:#{uid}"

  defp parse_remote_id("imap:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [uv, uid] ->
        {:ok, String.to_integer(uv), String.to_integer(uid)}

      _ ->
        {:error,
         %Error{class: :permanent, code: :invalid_message_id, message: "invalid IMAP message id"}}
    end
  rescue
    ArgumentError ->
      {:error,
       %Error{class: :permanent, code: :invalid_message_id, message: "invalid IMAP message id"}}
  end

  defp parse_remote_id(_id) do
    {:error,
     %Error{class: :permanent, code: :invalid_message_id, message: "invalid IMAP message id"}}
  end

  defp ensure_uidvalidity(expected, actual) when expected == actual, do: :ok

  defp ensure_uidvalidity(_expected, _actual) do
    {:error,
     %Error{
       class: :temporary,
       code: :uidvalidity_changed,
       message: "IMAP UIDVALIDITY changed"
     }}
  end
end

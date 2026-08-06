defmodule Manifold.Connectors.Provider.EAS do
  @moduledoc """
  Exchange ActiveSync Inbox synchronization adapter.

  Auth material is the plaintext mailbox password. Bodies are fetched via
  `fetch_raw/4`. Read flags are imported from Sync Add/Change and can be
  written back with `set_read/4`.

  Pass `retain_session: true` in provider opts so `sync_page/4` keeps the
  EAS connection open for subsequent `fetch_raw/4` calls in the same process.
  Call `release_session/0` when the page is finished.
  """

  @behaviour Manifold.Connectors.Provider

  import Ecto.Query

  alias Manifold.Connectors.Provider.{
    Error,
    Identity,
    Page,
    RawMessage,
    RemoteMessage,
    SyncCursor
  }

  alias Manifold.Connectors.Schema.SyncCursor, as: StoredCursor
  alias Manifold.Repo

  @default_page_size 25
  @session_key {__MODULE__, :session}

  @impl true
  def identity(_password, config, _opts) do
    email = Keyword.get(config, :email_address) || Keyword.fetch!(config, :username)

    {:ok,
     %Identity{
       id: "eas:" <> email,
       email_address: email
     }}
  end

  @impl true
  def initial_cursors(_password, config, _opts) do
    collection_id = Keyword.get(config, :collection_id) || "inbox"

    {:ok,
     [
       %SyncCursor{
         scope: "inbox",
         phase: "bootstrap",
         metadata: %{
           "collection_id" => collection_id,
           "sync_key" => "0",
           "folder_sync_key" => Keyword.get(config, :folder_sync_key, "0")
         }
       }
     ]}
  end

  @impl true
  def sync_page(password, %SyncCursor{} = cursor, config, opts) do
    transport = transport(config)
    page_size = Keyword.get(config, :page_size, @default_page_size)
    retain? = Keyword.get(opts, :retain_session, false)

    collection_id =
      metadata_get(cursor.metadata, "collection_id") || Keyword.get(config, :collection_id)

    sync_key = metadata_get(cursor.metadata, "sync_key") || "0"

    with {:ok, collection_id} <- require_collection_id(collection_id),
         {:ok, conn} <- ensure_conn(transport, password, config),
         {:ok, conn, result} <-
           sync_until_adds(transport, conn, collection_id, sync_key, page_size) do
      add_messages = Enum.map(result.adds, &to_remote_message(collection_id, &1))

      change_messages =
        Enum.map(Map.get(result, :changes, []), &to_remote_message(collection_id, &1))

      messages = add_messages ++ change_messages

      phase = if result.more_available?, do: "bootstrap", else: "incremental"

      page = %Page{
        messages: messages,
        cursor: %SyncCursor{
          cursor
          | phase: phase,
            metadata: %{
              "collection_id" => collection_id,
              "sync_key" => result.sync_key,
              "folder_sync_key" => metadata_get(cursor.metadata, "folder_sync_key") || "0"
            }
        }
      }

      if retain? do
        put_session(%{
          transport: transport,
          conn: conn,
          collection_id: collection_id
        })
      else
        transport.close(conn)
      end

      {:ok, page}
    else
      {:error, %Error{} = error} ->
        release_session()
        {:error, error}
    end
  end

  @impl true
  def fetch_raw(password, remote_message_id, config, _opts) do
    case get_session() do
      %{transport: transport, conn: conn, collection_id: collection_id} ->
        fetch_raw_on_session(transport, conn, collection_id, remote_message_id)

      nil ->
        fetch_raw_standalone(password, remote_message_id, config)
    end
  end

  @doc """
  Writes the Read flag back to Exchange via Sync Change.
  """
  @spec set_read(String.t(), String.t(), boolean(), keyword()) ::
          :ok | {:error, Error.t()}
  def set_read(password, remote_message_id, read?, config)
      when is_binary(password) and is_boolean(read?) do
    transport = transport(config)

    with {:ok, collection_id, server_id} <- parse_remote_id(remote_message_id),
         {:ok, sync_key, cursor} <- load_inbox_sync_key(config, collection_id),
         {:ok, conn} <- transport.connect(settings(password, config)),
         {:ok, conn, _} <- maybe_provision(transport, conn, config),
         {:ok, conn, %{sync_key: new_key}} <-
           transport.change_read(conn, %{
             collection_id: collection_id,
             server_id: server_id,
             read?: read?,
             sync_key: sync_key
           }),
         :ok <- persist_sync_key(cursor, new_key) do
      transport.close(conn)
      :ok
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @doc """
  Closes a process-local EAS session retained by `sync_page/4`.
  """
  @spec release_session() :: :ok
  def release_session do
    case Process.delete(@session_key) do
      %{transport: transport, conn: conn} ->
        transport.close(conn)
        :ok

      _ ->
        :ok
    end
  end

  defp to_remote_message(collection_id, %{server_id: server_id} = item) do
    %RemoteMessage{
      id: remote_id(collection_id, server_id),
      folder_id: collection_id,
      folder_kind: "inbox",
      read?: Map.get(item, :read?, false),
      received_at: Map.get(item, :received_at)
    }
  end

  defp sync_until_adds(transport, conn, collection_id, sync_key, page_size) do
    with {:ok, conn, result} <-
           transport.sync(conn, %{
             collection_id: collection_id,
             sync_key: sync_key,
             window_size: page_size
           }) do
      # SyncKey 0 handshake often returns no Adds; immediately request the next page.
      if sync_key == "0" and result.adds == [] and Map.get(result, :changes, []) == [] and
           result.sync_key != sync_key do
        transport.sync(conn, %{
          collection_id: collection_id,
          sync_key: result.sync_key,
          window_size: page_size
        })
      else
        {:ok, conn, result}
      end
    end
  end

  defp fetch_raw_on_session(transport, conn, collection_id, remote_message_id) do
    with {:ok, expected_collection, server_id} <- parse_remote_id(remote_message_id),
         :ok <- ensure_collection(collection_id, expected_collection),
         {:ok, bytes} <- transport.fetch_mime(conn, collection_id, server_id) do
      {:ok,
       %RawMessage{
         bytes: bytes,
         folder_id: collection_id,
         folder_kind: "inbox"
       }}
    end
  end

  defp fetch_raw_standalone(password, remote_message_id, config) do
    transport = transport(config)

    with {:ok, collection_id, server_id} <- parse_remote_id(remote_message_id),
         {:ok, conn} <- transport.connect(settings(password, config)),
         {:ok, conn, _} <- maybe_provision(transport, conn, config),
         {:ok, bytes} <- transport.fetch_mime(conn, collection_id, server_id) do
      transport.close(conn)

      {:ok,
       %RawMessage{
         bytes: bytes,
         folder_id: collection_id,
         folder_kind: "inbox"
       }}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp load_inbox_sync_key(config, collection_id) do
    account_id = Keyword.get(config, :account_id)
    sync_key = Keyword.get(config, :sync_key)

    cond do
      is_binary(sync_key) and sync_key != "" ->
        {:ok, sync_key, nil}

      is_binary(account_id) ->
        case Repo.one(
               from(c in StoredCursor,
                 where: c.external_account_id == ^account_id and c.scope == "inbox",
                 limit: 1
               )
             ) do
          %StoredCursor{} = cursor ->
            key = metadata_get(cursor.metadata, "sync_key") || "0"
            coll = metadata_get(cursor.metadata, "collection_id") || collection_id

            if coll == collection_id do
              {:ok, key, cursor}
            else
              {:ok, key, cursor}
            end

          nil ->
            {:error,
             %Error{
               class: :permanent,
               code: :sync_key_missing,
               message: "EAS sync key is missing"
             }}
        end

      true ->
        {:error,
         %Error{
           class: :permanent,
           code: :sync_key_missing,
           message: "EAS sync key is missing"
         }}
    end
  end

  defp persist_sync_key(nil, _new_key), do: :ok

  defp persist_sync_key(%StoredCursor{} = cursor, new_key) when is_binary(new_key) do
    metadata = Map.put(cursor.metadata || %{}, "sync_key", new_key)

    cursor
    |> StoredCursor.changeset(%{metadata: metadata})
    |> Repo.update()
    |> case do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  defp ensure_conn(transport, password, config) do
    case get_session() do
      %{transport: ^transport, conn: conn} ->
        {:ok, conn}

      %{transport: other, conn: conn} ->
        other.close(conn)
        Process.delete(@session_key)
        open_conn(transport, password, config)

      nil ->
        open_conn(transport, password, config)
    end
  end

  defp open_conn(transport, password, config) do
    with {:ok, conn} <- transport.connect(settings(password, config)),
         {:ok, conn, _} <- maybe_provision(transport, conn, config) do
      {:ok, conn}
    end
  end

  defp maybe_provision(transport, conn, config) do
    case Keyword.get(config, :policy_key) do
      key when is_binary(key) and key not in ["", "0"] ->
        {:ok, conn, %{policy_key: key}}

      _ ->
        transport.provision(conn)
    end
  end

  defp settings(password, config) do
    base = %{
      host: Keyword.fetch!(config, :host),
      port: Keyword.fetch!(config, :port),
      path: Keyword.get(config, :path, "/Microsoft-Server-ActiveSync"),
      domain: Keyword.get(config, :domain),
      username: Keyword.fetch!(config, :username),
      password: password,
      device_id: Keyword.fetch!(config, :device_id),
      device_type: Keyword.get(config, :device_type, "iPhone"),
      protocol_version: Keyword.get(config, :protocol_version, "14.1"),
      policy_key: Keyword.get(config, :policy_key),
      account_id: Keyword.get(config, :account_id),
      emit_activity: Keyword.get(config, :emit_activity, true),
      req_options: Keyword.get(config, :req_options, [])
    }

    fake = Keyword.get(config, :fake, %{})
    Map.merge(base, if(is_map(fake), do: fake, else: %{}))
  end

  defp transport(config) do
    Keyword.get(config, :transport) ||
      Application.get_env(:manifold_connectors, :eas_transport, Manifold.Connectors.EAS.Client)
  end

  defp require_collection_id(nil),
    do:
      {:error,
       %Error{
         class: :permanent,
         code: :eas_collection_missing,
         message: "EAS Inbox collection id is missing"
       }}

  defp require_collection_id(id) when is_binary(id), do: {:ok, id}

  defp remote_id(collection_id, server_id), do: "#{collection_id}:#{server_id}"

  defp parse_remote_id(remote_message_id) when is_binary(remote_message_id) do
    case String.split(remote_message_id, ":", parts: 2) do
      [collection_id, server_id] when collection_id != "" and server_id != "" ->
        {:ok, collection_id, server_id}

      _ ->
        {:error,
         %Error{
           class: :permanent,
           code: :invalid_remote_id,
           message: "invalid EAS remote message id"
         }}
    end
  end

  defp ensure_collection(selected, expected) when selected == expected, do: :ok

  defp ensure_collection(_selected, _expected) do
    {:error,
     %Error{
       class: :permanent,
       code: :collection_mismatch,
       message: "EAS collection id mismatch"
     }}
  end

  defp metadata_get(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))
  end

  defp metadata_get(_, _), do: nil

  defp put_session(session), do: Process.put(@session_key, session)
  defp get_session, do: Process.get(@session_key)
end

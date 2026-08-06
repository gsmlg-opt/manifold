defmodule Manifold.Connectors.Provider.IMAP do
  @moduledoc """
  Read-only IMAP INBOX synchronization adapter.

  Auth material is the plaintext mailbox password. Bodies are fetched via
  `fetch_raw/4`; `sync_page/4` enumerates UIDs and synchronizes `\\Seen` flags.

  Pass `retain_session: true` in provider opts so `sync_page/4` keeps the
  IMAP connection open for subsequent `fetch_raw/4` calls in the same process.
  Call `release_session/0` when the page is finished.
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
  @session_key {__MODULE__, :session}

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
  def sync_page(password, %SyncCursor{} = cursor, config, opts) do
    transport = transport(config)
    mailbox_path = Keyword.get(config, :mailbox_path, cursor.scope || "INBOX")
    page_size = Keyword.get(config, :page_size, @default_page_size)
    retain? = Keyword.get(opts, :retain_session, false)

    with {:ok, conn} <- transport.connect(settings(password, config)),
         {:ok, %{uidvalidity: uidvalidity}} <- transport.select(conn, mailbox_path),
         {:ok, uids} <- transport.uid_search(conn, "ALL"),
         {:ok, page} <-
           build_page(transport, conn, cursor, uids, uidvalidity, mailbox_path, page_size) do
      if retain? do
        put_session(%{
          transport: transport,
          conn: conn,
          uidvalidity: uidvalidity,
          mailbox_path: mailbox_path
        })
      else
        transport.logout(conn)
      end

      {:ok, page}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @impl true
  def fetch_raw(password, remote_message_id, config, _opts) do
    case get_session() do
      %{transport: transport, conn: conn, uidvalidity: selected_uv, mailbox_path: mailbox_path} ->
        fetch_raw_on_session(transport, conn, selected_uv, mailbox_path, remote_message_id)

      nil ->
        fetch_raw_standalone(password, remote_message_id, config)
    end
  end

  @doc """
  Closes a process-local IMAP session retained by `sync_page/4`.
  """
  @spec release_session() :: :ok
  def release_session do
    case Process.delete(@session_key) do
      %{transport: transport, conn: conn} ->
        transport.logout(conn)
        :ok

      _ ->
        :ok
    end
  end

  @doc """
  Adds or removes the `\\Seen` flag for a previously synced IMAP message.
  """
  @spec set_read(String.t(), String.t(), boolean(), keyword()) ::
          :ok | {:error, Error.t()}
  def set_read(password, remote_message_id, read?, config)
      when is_binary(password) and is_boolean(read?) do
    transport = transport(config)
    mailbox_path = Keyword.get(config, :mailbox_path, "INBOX")
    op = if(read?, do: :add, else: :remove)

    with {:ok, uidvalidity, uid} <- parse_remote_id(remote_message_id),
         {:ok, conn} <- transport.connect(settings(password, config)),
         {:ok, %{uidvalidity: selected_uv}} <- transport.select(conn, mailbox_path),
         :ok <- ensure_uidvalidity(uidvalidity, selected_uv),
         :ok <- transport.uid_store_flags(conn, uid, op, ["\\Seen"]) do
      transport.logout(conn)
      :ok
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp build_page(transport, conn, cursor, uids, uidvalidity, mailbox_path, page_size) do
    metadata = normalize_metadata(cursor.metadata, uidvalidity)
    last_uid = Map.get(metadata, "last_uid", 0)
    flags_scan_uid = Map.get(metadata, "flags_scan_uid", 0)
    boosted_until = Map.get(metadata, "boosted_until", last_uid)
    sorted_uids = Enum.sort(uids)
    max_uid = List.last(sorted_uids) || 0
    recent_until = Map.get(metadata, "recent_until") || max_uid + 1

    pending_flag_uids =
      sorted_uids
      |> Enum.filter(&(&1 <= last_uid and &1 > flags_scan_uid))
      |> Enum.take(page_size)

    pending_all = Enum.filter(sorted_uids, &(&1 > last_uid))
    history_uids = Enum.take(pending_all, page_size)

    # Newest-first only for UIDs beyond the next sequential history page,
    # so small mailboxes and post-boost catch-up stay on the history path.
    pending_recent =
      pending_all
      |> Enum.drop(page_size)
      |> Enum.filter(&(&1 < recent_until))
      |> Enum.take(-page_size)

    prefer_recent? = length(pending_all) > page_size and pending_recent != []

    # Priority while bootstrapping a large mailbox:
    # 1) UNSEEN boost (unread counts matter immediately)
    # 2) newest-first catch-up when history watermark lags far behind
    # 3) FLAGS repair for already-imported UIDs
    # 4) sequential history from last_uid upward
    case boost_unseen_uids(
           transport,
           conn,
           last_uid,
           boosted_until,
           page_size,
           sorted_uids
         ) do
      {:ok, [_ | _] = boost_uids} ->
        build_boost_uid_page(
          transport,
          conn,
          cursor,
          metadata,
          sorted_uids,
          boost_uids,
          uidvalidity,
          mailbox_path,
          last_uid,
          recent_until
        )

      _ ->
        cond do
          prefer_recent? ->
            build_recent_uid_page(
              transport,
              conn,
              cursor,
              metadata,
              sorted_uids,
              pending_recent,
              uidvalidity,
              mailbox_path,
              last_uid,
              recent_until
            )

          pending_flag_uids != [] ->
            build_flags_scan_page(
              transport,
              conn,
              cursor,
              metadata,
              sorted_uids,
              uidvalidity,
              mailbox_path,
              last_uid,
              page_size,
              recent_until
            )

          history_uids != [] ->
            build_new_uid_page(
              transport,
              conn,
              cursor,
              metadata,
              sorted_uids,
              history_uids,
              uidvalidity,
              mailbox_path,
              last_uid,
              recent_until
            )

          true ->
            build_flags_scan_page(
              transport,
              conn,
              cursor,
              metadata,
              sorted_uids,
              uidvalidity,
              mailbox_path,
              last_uid,
              page_size,
              recent_until
            )
        end
    end
  end

  defp boost_unseen_uids(transport, conn, last_uid, boosted_until, page_size, sorted_uids) do
    floor = max(last_uid, boosted_until)

    next_page_end =
      sorted_uids
      |> Enum.filter(&(&1 > last_uid))
      |> Enum.take(page_size)
      |> List.last() || last_uid

    case transport.uid_search(conn, "UNSEEN") do
      {:ok, unseen} ->
        boost_uids =
          unseen
          |> Enum.filter(&(&1 > floor and &1 > next_page_end))
          |> Enum.sort()
          |> Enum.take(page_size)

        {:ok, boost_uids}

      {:error, _} = error ->
        error
    end
  end

  defp build_boost_uid_page(
         transport,
         conn,
         cursor,
         metadata,
         sorted_uids,
         page_uids,
         uidvalidity,
         mailbox_path,
         last_uid,
         recent_until
       ) do
    with {:ok, flags_by_uid} <- transport.uid_fetch_flags(conn, page_uids) do
      messages = remote_messages(page_uids, uidvalidity, mailbox_path, flags_by_uid)
      new_boosted = List.last(page_uids)
      more_new? = Enum.any?(sorted_uids, &(&1 > last_uid))
      flags_scan_uid = Map.get(metadata, "flags_scan_uid", last_uid)
      # Treat boosted UIDs as already covered by the recent watermark so the
      # newest-first walker continues below them instead of re-fetching.
      new_recent_until = min(recent_until, List.first(Enum.sort(page_uids)))

      {:ok,
       %Page{
         messages: messages,
         cursor: %SyncCursor{
           cursor
           | phase: if(more_new?, do: "bootstrap", else: "incremental"),
             page_cursor: if(more_new?, do: "boost:#{new_boosted}", else: nil),
             metadata: %{
               "uidvalidity" => uidvalidity,
               "last_uid" => last_uid,
               "flags_scan_uid" => if(more_new?, do: flags_scan_uid, else: 0),
               "boosted_until" => new_boosted,
               "recent_until" => new_recent_until
             }
         }
       }}
    end
  end

  defp build_recent_uid_page(
         transport,
         conn,
         cursor,
         _metadata,
         sorted_uids,
         page_uids,
         uidvalidity,
         mailbox_path,
         last_uid,
         _recent_until
       ) do
    with {:ok, flags_by_uid} <- transport.uid_fetch_flags(conn, page_uids) do
      messages = remote_messages(page_uids, uidvalidity, mailbox_path, flags_by_uid)
      sorted_page = Enum.sort(page_uids)
      new_recent_until = List.first(sorted_page)
      more_new? = Enum.any?(sorted_uids, &(&1 > last_uid))

      boosted_until =
        max(Map.get(cursor.metadata || %{}, "boosted_until", 0), List.last(sorted_page))

      {:ok,
       %Page{
         messages: messages,
         cursor: %SyncCursor{
           cursor
           | phase: if(more_new?, do: "bootstrap", else: "incremental"),
             page_cursor: if(more_new?, do: "recent:#{new_recent_until}", else: nil),
             metadata: %{
               "uidvalidity" => uidvalidity,
               "last_uid" => last_uid,
               "flags_scan_uid" => Map.get(cursor.metadata || %{}, "flags_scan_uid", last_uid),
               "boosted_until" => boosted_until,
               "recent_until" => new_recent_until
             }
         }
       }}
    end
  end

  defp build_new_uid_page(
         transport,
         conn,
         cursor,
         metadata,
         sorted_uids,
         page_uids,
         uidvalidity,
         mailbox_path,
         _last_uid,
         recent_until
       ) do
    with {:ok, flags_by_uid} <- transport.uid_fetch_flags(conn, page_uids) do
      messages = remote_messages(page_uids, uidvalidity, mailbox_path, flags_by_uid)
      new_last_uid = List.last(page_uids)
      more_new? = Enum.any?(sorted_uids, &(&1 > new_last_uid))
      phase = if more_new?, do: "bootstrap", else: "incremental"
      boosted_until = max(Map.get(metadata, "boosted_until", 0), new_last_uid)

      # New UIDs already received correct FLAGS on this page, so the scan
      # cursor can advance with last_uid instead of being reset to 0.
      page_cursor =
        cond do
          more_new? -> "new:#{new_last_uid}"
          true -> nil
        end

      {:ok,
       %Page{
         messages: messages,
         cursor: %SyncCursor{
           cursor
           | phase: phase,
             page_cursor: page_cursor,
             metadata: %{
               "uidvalidity" => uidvalidity,
               "last_uid" => new_last_uid,
               "flags_scan_uid" => new_last_uid,
               "boosted_until" => boosted_until,
               "recent_until" => max(recent_until, new_last_uid + 1)
             }
         }
       }}
    end
  end

  defp build_flags_scan_page(
         transport,
         conn,
         cursor,
         metadata,
         sorted_uids,
         uidvalidity,
         mailbox_path,
         last_uid,
         page_size,
         recent_until
       ) do
    scan_after = Map.get(metadata, "flags_scan_uid", 0)
    boosted_until = Map.get(metadata, "boosted_until", last_uid)
    # Include boosted/recent UIDs ahead of last_uid so INTERNALDATE/FLAGS repair
    # covers messages imported out of order during UNSEEN/recent catch-up.
    scan_until = max(last_uid, boosted_until)

    refresh_uids =
      sorted_uids
      |> Enum.filter(&(&1 <= scan_until and &1 > scan_after))
      |> Enum.take(page_size)

    case refresh_uids do
      [] ->
        more_new? = Enum.any?(sorted_uids, &(&1 > last_uid))

        {:ok,
         %Page{
           messages: [],
           cursor: %SyncCursor{
             cursor
             | phase: if(more_new?, do: "bootstrap", else: "incremental"),
               page_cursor: if(more_new?, do: "new:#{last_uid}", else: nil),
               metadata: %{
                 "uidvalidity" => uidvalidity,
                 "last_uid" => last_uid,
                 # Ready for the next full FLAGS pass once bootstrap settles.
                 "flags_scan_uid" => if(more_new?, do: last_uid, else: 0),
                 "boosted_until" => boosted_until,
                 "recent_until" => recent_until
               }
           }
         }}

      page_uids ->
        with {:ok, flags_by_uid} <- transport.uid_fetch_flags(conn, page_uids) do
          messages = remote_messages(page_uids, uidvalidity, mailbox_path, flags_by_uid)
          new_scan_uid = List.last(page_uids)
          more_flags? = Enum.any?(sorted_uids, &(&1 <= scan_until and &1 > new_scan_uid))
          more_new? = Enum.any?(sorted_uids, &(&1 > last_uid))

          page_cursor =
            cond do
              more_flags? -> "flags:#{new_scan_uid}"
              more_new? -> "new:#{last_uid}"
              true -> nil
            end

          phase =
            cond do
              more_flags? or more_new? -> "bootstrap"
              true -> "incremental"
            end

          {:ok,
           %Page{
             messages: messages,
             cursor: %SyncCursor{
               cursor
               | phase: phase,
                 page_cursor: page_cursor,
                 metadata: %{
                   "uidvalidity" => uidvalidity,
                   "last_uid" => last_uid,
                   "flags_scan_uid" =>
                     cond do
                       more_flags? -> new_scan_uid
                       more_new? -> last_uid
                       true -> 0
                     end,
                   "boosted_until" => boosted_until,
                   "recent_until" => recent_until
                 }
             }
           }}
        end
    end
  end

  defp remote_messages(uids, uidvalidity, mailbox_path, meta_by_uid) do
    Enum.map(uids, fn uid ->
      meta = Map.get(meta_by_uid, uid, %{flags: [], received_at: nil})
      flags = Map.get(meta, :flags, [])

      %RemoteMessage{
        id: remote_id(uidvalidity, uid),
        folder_id: mailbox_path,
        folder_kind: "inbox",
        read?: Client.seen?(flags),
        received_at: Map.get(meta, :received_at)
      }
    end)
  end

  defp fetch_raw_on_session(transport, conn, selected_uv, mailbox_path, remote_message_id) do
    with {:ok, uidvalidity, uid} <- parse_remote_id(remote_message_id),
         :ok <- ensure_uidvalidity(uidvalidity, selected_uv),
         {:ok, bytes} <- transport.uid_fetch_rfc822(conn, uid),
         {:ok, meta_by_uid} <- transport.uid_fetch_flags(conn, [uid]) do
      meta = Map.get(meta_by_uid, uid, %{flags: [], received_at: nil})
      flags = Map.get(meta, :flags, [])

      {:ok,
       %RawMessage{
         bytes: bytes,
         folder_id: mailbox_path,
         folder_kind: "inbox",
         read?: Client.seen?(flags),
         received_at: Map.get(meta, :received_at)
       }}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp fetch_raw_standalone(password, remote_message_id, config) do
    transport = transport(config)
    mailbox_path = Keyword.get(config, :mailbox_path, "INBOX")
    settings = Map.put(settings(password, config), :emit_activity, false)

    with {:ok, uidvalidity, uid} <- parse_remote_id(remote_message_id),
         {:ok, conn} <- transport.connect(settings),
         {:ok, %{uidvalidity: selected_uv}} <- transport.select(conn, mailbox_path),
         :ok <- ensure_uidvalidity(uidvalidity, selected_uv),
         {:ok, bytes} <- transport.uid_fetch_rfc822(conn, uid),
         {:ok, meta_by_uid} <- transport.uid_fetch_flags(conn, [uid]) do
      transport.logout(conn)
      meta = Map.get(meta_by_uid, uid, %{flags: [], received_at: nil})
      flags = Map.get(meta, :flags, [])

      {:ok,
       %RawMessage{
         bytes: bytes,
         folder_id: mailbox_path,
         folder_kind: "inbox",
         read?: Client.seen?(flags),
         received_at: Map.get(meta, :received_at)
       }}
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp put_session(session), do: Process.put(@session_key, session)

  defp get_session, do: Process.get(@session_key)

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

    base =
      case Keyword.get(config, :account_id) do
        id when is_binary(id) -> Map.put(base, :account_id, id)
        _ -> base
      end

    case Keyword.get(config, :fake) do
      %{} = fake -> Map.merge(base, fake)
      _ -> base
    end
  end

  defp normalize_metadata(metadata, uidvalidity) when is_map(metadata) do
    stored = metadata["uidvalidity"] || metadata[:uidvalidity]

    cond do
      is_nil(stored) ->
        %{
          "uidvalidity" => uidvalidity,
          "last_uid" => 0,
          "flags_scan_uid" => 0,
          "boosted_until" => 0
        }

      stored == uidvalidity ->
        last = metadata["last_uid"] || metadata[:last_uid] || 0
        flags_scan = metadata["flags_scan_uid"] || metadata[:flags_scan_uid] || 0
        boosted = metadata["boosted_until"] || metadata[:boosted_until] || last
        recent = metadata["recent_until"] || metadata[:recent_until]

        base = %{
          "uidvalidity" => uidvalidity,
          "last_uid" => last,
          "flags_scan_uid" => flags_scan,
          "boosted_until" => boosted
        }

        if is_integer(recent) and recent > 0 do
          Map.put(base, "recent_until", recent)
        else
          base
        end

      true ->
        %{
          "uidvalidity" => uidvalidity,
          "last_uid" => 0,
          "flags_scan_uid" => 0,
          "boosted_until" => 0
        }
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

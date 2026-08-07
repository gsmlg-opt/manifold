defmodule Manifold.Mail.Mailbox do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Core.Error
  alias Manifold.Mail.Folders

  alias Manifold.Mail.Schema.{
    Attachment,
    Folder,
    MailboxEntry,
    Message,
    MessageAddress,
    Thread
  }

  alias Manifold.Mail.View
  alias Manifold.Repo
  alias Manifold.Storage.BlobStore

  @default_limit 50
  @max_limit 100

  @spec list_folders(Ecto.UUID.t()) :: {:ok, [View.Folder.t()]} | {:error, Error.t()}
  def list_folders(mailbox_id) do
    with {:ok, _folders} <- Folders.ensure(mailbox_id) do
      counts =
        from(entry in MailboxEntry,
          where:
            entry.mailbox_id == ^mailbox_id and not is_nil(entry.folder_id) and
              not entry.quarantined,
          group_by: entry.folder_id,
          select: {
            entry.folder_id,
            count(entry.id),
            filter(count(entry.id), is_nil(entry.read_at))
          }
        )
        |> Repo.all()
        |> Map.new(fn {folder_id, total, unread} -> {folder_id, {total, unread}} end)

      folders =
        Folder
        |> where([folder], folder.mailbox_id == ^mailbox_id)
        |> order_by(
          [folder],
          asc:
            fragment(
              "CASE ? WHEN 'inbox' THEN 0 WHEN 'archive' THEN 1 WHEN 'trash' THEN 2 ELSE 3 END",
              folder.kind
            ),
          asc: folder.name
        )
        |> Repo.all()
        |> Enum.map(fn folder ->
          {total, unread} = Map.get(counts, folder.id, {0, 0})

          %View.Folder{
            id: folder.id,
            kind: folder.kind,
            name: folder.name,
            total_count: total,
            unread_count: unread
          }
        end)

      {:ok, folders}
    else
      {:error, reason} -> {:error, database_error(reason)}
    end
  end

  @spec list_conversations(Ecto.UUID.t(), Ecto.UUID.t(), Keyword.t()) ::
          {:ok, View.ConversationPage.t()} | {:error, Error.t()}
  def list_conversations(mailbox_id, folder_id, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> min(@max_limit) |> max(1)
    query = opts |> Keyword.get(:query, "") |> String.trim() |> String.slice(0, 200)
    unread_only? = Keyword.get(opts, :unread_only, false) in [true, "true", "1", 1]

    if valid_uuids?([mailbox_id, folder_id]) and
         Folders.belongs_to_mailbox?(folder_id, mailbox_id) do
      folder_threads =
        Thread
        |> join(:inner, [thread], entry in MailboxEntry, on: entry.thread_id == thread.id)
        |> join(:inner, [_thread, entry], message in Message, on: message.id == entry.message_id)
        |> where(
          [thread, entry, _message],
          thread.mailbox_id == ^mailbox_id and entry.mailbox_id == ^mailbox_id and
            entry.folder_id == ^folder_id and not entry.quarantined
        )
        |> maybe_search_threads(query)
        |> maybe_unread_only(unread_only?)
        |> group_by([thread], thread.id)
        |> select([thread, entry, message], %{
          thread_id: thread.id,
          last_message_at:
            type(
              max(
                fragment(
                  "COALESCE(?, ?, ?)",
                  message.received_at,
                  message.sent_at,
                  entry.inserted_at
                )
              ),
              :utc_datetime_usec
            ),
          message_count: count(entry.id)
        })

      page_rows =
        folder_threads
        |> subquery()
        |> maybe_after_thread_cursor(Keyword.get(opts, :after))
        |> order_by([row], desc: row.last_message_at, desc: row.thread_id)
        |> limit(^(limit + 1))
        |> Repo.all()

      selected_page_rows = Enum.take(page_rows, limit)
      thread_ids = Enum.map(selected_page_rows, & &1.thread_id)
      thread_metadata = Map.new(selected_page_rows, &{&1.thread_id, &1})

      rows =
        from(entry in MailboxEntry,
          join: message in Message,
          on: message.id == entry.message_id,
          where:
            entry.mailbox_id == ^mailbox_id and entry.folder_id == ^folder_id and
              entry.thread_id in ^thread_ids and not entry.quarantined,
          order_by: [
            desc:
              fragment(
                "COALESCE(?, ?, ?)",
                message.received_at,
                message.sent_at,
                entry.inserted_at
              ),
            desc: entry.id
          ],
          select: %{
            entry_id: entry.id,
            thread_id: entry.thread_id,
            message_id: message.id,
            subject: message.subject,
            sender_name: message.sender_name,
            sender_address: message.sender_address,
            text_body: message.text_body,
            read_at: entry.read_at,
            starred_at: entry.starred_at
          }
        )
        |> Repo.all()

      items =
        rows
        |> Enum.group_by(& &1.thread_id)
        |> then(fn rows_by_thread ->
          Enum.flat_map(thread_ids, fn thread_id ->
            case Map.fetch(rows_by_thread, thread_id) do
              {:ok, thread_rows} -> [summary(thread_rows, Map.fetch!(thread_metadata, thread_id))]
              :error -> []
            end
          end)
        end)
        |> add_attachment_counts(mailbox_id, folder_id)

      next_cursor =
        case {length(page_rows) > limit, List.last(selected_page_rows)} do
          {true, %{last_message_at: at, thread_id: thread_id}} ->
            encode_cursor(at, thread_id)

          _other ->
            nil
        end

      {:ok, %View.ConversationPage{items: items, next_cursor: next_cursor}}
    else
      {:error, error(:permanent, :not_found, "folder not found in mailbox")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec search(Ecto.UUID.t(), String.t(), Keyword.t()) ::
          {:ok, View.ConversationPage.t()} | {:error, Error.t()}
  def search(mailbox_id, query, opts \\ []) do
    with {:ok, folders} <- list_folders(mailbox_id),
         %View.Folder{id: inbox_id} <- Enum.find(folders, &(&1.kind == "inbox")) do
      list_conversations(mailbox_id, Keyword.get(opts, :folder_id, inbox_id),
        query: query,
        limit: Keyword.get(opts, :limit, @default_limit),
        after: Keyword.get(opts, :after)
      )
    else
      nil -> {:error, error(:permanent, :not_found, "inbox folder not found")}
      {:error, %Error{}} = failure -> failure
    end
  end

  @spec get_conversation(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, View.Conversation.t()} | {:error, Error.t()}
  def get_conversation(mailbox_id, thread_id) do
    if valid_uuids?([mailbox_id, thread_id]) do
      load_conversation(mailbox_id, thread_id)
    else
      {:error, error(:permanent, :not_found, "conversation not found in mailbox")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec get_conversation(Ecto.UUID.t(), Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, View.Conversation.t()} | {:error, Error.t()}
  def get_conversation(mailbox_id, folder_id, thread_id) do
    if valid_uuids?([mailbox_id, folder_id, thread_id]) and
         Folders.belongs_to_mailbox?(folder_id, mailbox_id) do
      load_conversation(mailbox_id, thread_id, folder_id)
    else
      {:error, error(:permanent, :not_found, "conversation not found in mailbox folder")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  defp load_conversation(mailbox_id, thread_id, folder_id \\ nil) do
    rows =
      from(entry in MailboxEntry,
        join: message in Message,
        on: message.id == entry.message_id,
        where:
          entry.mailbox_id == ^mailbox_id and entry.thread_id == ^thread_id and
            not entry.quarantined,
        order_by: [
          asc:
            fragment(
              "COALESCE(?, ?, ?)",
              message.received_at,
              message.sent_at,
              entry.inserted_at
            ),
          asc: entry.id
        ],
        select: %{entry: entry, message: message}
      )
      |> maybe_in_folder(folder_id)
      |> Repo.all()

    case rows do
      [] ->
        {:error, error(:permanent, :not_found, "conversation not found in mailbox folder")}

      rows ->
        messages = Enum.map(rows, &message_view/1)
        subject = rows |> List.last() |> get_in([:message, Access.key(:subject)])

        {:ok,
         %View.Conversation{
           thread_id: thread_id,
           subject: subject || "(No subject)",
           messages: messages
         }}
    end
  end

  @spec get_message_body(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def get_message_body(mailbox_id, message_id) do
    if valid_uuids?([mailbox_id, message_id]) do
      query =
        from(entry in MailboxEntry,
          join: message in Message,
          on: message.id == entry.message_id,
          where:
            entry.mailbox_id == ^mailbox_id and message.id == ^message_id and
              not entry.quarantined,
          select: message.sanitized_html
        )

      case Repo.one(query) do
        body when is_binary(body) -> {:ok, body}
        nil -> {:error, error(:permanent, :not_found, "HTML message body not found")}
      end
    else
      {:error, error(:permanent, :not_found, "HTML message body not found")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec get_reply_source(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, View.ReplySource.t()} | {:error, Error.t()}
  def get_reply_source(mailbox_id, message_id) do
    if valid_uuids?([mailbox_id, message_id]) do
      message =
        from(entry in MailboxEntry,
          join: message in Message,
          on: message.id == entry.message_id,
          where:
            entry.mailbox_id == ^mailbox_id and message.id == ^message_id and
              not entry.quarantined,
          limit: 1,
          select: message
        )
        |> Repo.one()

      case message do
        %Message{} = message -> {:ok, reply_source(message)}
        nil -> {:error, error(:permanent, :not_found, "reply source not found in mailbox")}
      end
    else
      {:error, error(:permanent, :not_found, "reply source not found in mailbox")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec mark_read(Ecto.UUID.t(), [Ecto.UUID.t()], boolean()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def mark_read(mailbox_id, entry_ids, read?) when is_boolean(read?) do
    result =
      update_entries(mailbox_id, entry_ids, read_at: if(read?, do: DateTime.utc_now(), else: nil))

    case result do
      {:ok, count} when count > 0 ->
        :telemetry.execute(
          [:manifold, :mail, :mailbox, :read_changed],
          %{entry_count: count},
          %{mailbox_id: mailbox_id, entry_ids: entry_ids, read?: read?}
        )

        result

      other ->
        other
    end
  end

  @spec entry_ids_for_threads(Ecto.UUID.t(), Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, [Ecto.UUID.t()]} | {:error, Error.t()}
  def entry_ids_for_threads(mailbox_id, folder_id, thread_ids) when is_list(thread_ids) do
    ids = [mailbox_id, folder_id | thread_ids]

    if valid_uuids?(ids) do
      if thread_ids == [] do
        {:ok, []}
      else
        entry_ids =
          from(entry in MailboxEntry,
            where:
              entry.mailbox_id == ^mailbox_id and entry.folder_id == ^folder_id and
                entry.thread_id in ^thread_ids and not entry.quarantined,
            select: entry.id
          )
          |> Repo.all()

        {:ok, entry_ids}
      end
    else
      {:error, error(:permanent, :not_found, "invalid mailbox, folder, or thread id")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec mark_folder_read(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def mark_folder_read(mailbox_id, folder_id) do
    if valid_uuids?([mailbox_id, folder_id]) and
         Folders.belongs_to_mailbox?(folder_id, mailbox_id) do
      entry_ids =
        from(entry in MailboxEntry,
          where:
            entry.mailbox_id == ^mailbox_id and entry.folder_id == ^folder_id and
              is_nil(entry.read_at) and not entry.quarantined,
          select: entry.id
        )
        |> Repo.all()

      case mark_read(mailbox_id, entry_ids, true) do
        {:ok, _count} -> {:ok, length(entry_ids)}
        error -> error
      end
    else
      {:error, error(:permanent, :not_found, "folder not found in mailbox")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec set_starred(Ecto.UUID.t(), [Ecto.UUID.t()], boolean()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def set_starred(mailbox_id, entry_ids, starred?) when is_boolean(starred?) do
    update_entries(
      mailbox_id,
      entry_ids,
      starred_at: if(starred?, do: DateTime.utc_now(), else: nil)
    )
  end

  @spec move(Ecto.UUID.t(), [Ecto.UUID.t()], Ecto.UUID.t()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def move(mailbox_id, entry_ids, folder_id) do
    if Folders.belongs_to_mailbox?(folder_id, mailbox_id) do
      Repo.transaction(fn ->
        entries =
          scoped_entries(mailbox_id, entry_ids)
          |> where([entry], entry.folder_id != ^folder_id)
          |> lock("FOR UPDATE")
          |> Repo.all()

        Enum.each(entries, fn entry ->
          entry
          |> MailboxEntry.changeset(%{
            previous_folder_id: entry.folder_id,
            folder_id: folder_id
          })
          |> Repo.update!()
        end)

        length(entries)
      end)
      |> normalize_transaction()
      |> notify_change(mailbox_id)
    else
      {:error, error(:permanent, :not_found, "destination folder not found in mailbox")}
    end
  end

  @spec archive(Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def archive(mailbox_id, entry_ids), do: move_to_system(mailbox_id, entry_ids, "archive")

  @spec trash(Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def trash(mailbox_id, entry_ids), do: move_to_system(mailbox_id, entry_ids, "trash")

  @spec restore(Ecto.UUID.t(), [Ecto.UUID.t()]) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def restore(mailbox_id, entry_ids) do
    with {:ok, folders} <- Folders.ensure(mailbox_id) do
      Repo.transaction(fn ->
        restorable_folder_ids = [folders.archive.id, folders.trash.id]

        valid_target_ids =
          Folder
          |> where(
            [folder],
            folder.mailbox_id == ^mailbox_id and folder.kind in ^~w(inbox archive custom)
          )
          |> select([folder], folder.id)
          |> Repo.all()
          |> MapSet.new()

        entries =
          scoped_entries(mailbox_id, entry_ids)
          |> where(
            [entry],
            entry.folder_id in ^restorable_folder_ids and not is_nil(entry.previous_folder_id)
          )
          |> lock("FOR UPDATE")
          |> Repo.all()

        Enum.each(entries, fn entry ->
          target =
            if MapSet.member?(valid_target_ids, entry.previous_folder_id) do
              entry.previous_folder_id
            else
              folders.inbox.id
            end

          entry
          |> MailboxEntry.changeset(%{folder_id: target, previous_folder_id: nil})
          |> Repo.update!()
        end)

        length(entries)
      end)
      |> normalize_transaction()
      |> notify_change(mailbox_id)
    else
      {:error, reason} -> {:error, database_error(reason)}
    end
  end

  @spec open_attachment(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, View.AttachmentDownload.t()} | {:error, Error.t()}
  def open_attachment(mailbox_id, attachment_id) do
    if valid_uuids?([mailbox_id, attachment_id]) do
      attachment =
        from(attachment in Attachment,
          join: entry in MailboxEntry,
          on: entry.message_id == attachment.message_id,
          where:
            entry.mailbox_id == ^mailbox_id and attachment.id == ^attachment_id and
              not entry.quarantined,
          limit: 1,
          select: attachment
        )
        |> Repo.one()

      case attachment do
        %Attachment{} ->
          case BlobStore.open(attachment.object_key) do
            {:ok, io} ->
              {:ok,
               %View.AttachmentDownload{
                 filename: attachment.filename || "attachment",
                 media_type: attachment.media_type,
                 size: attachment.size,
                 io: io
               }}

            {:error, reason} ->
              {:error, storage_error(reason)}
          end

        nil ->
          {:error, error(:permanent, :not_found, "attachment not found in mailbox")}
      end
    else
      {:error, error(:permanent, :not_found, "attachment not found in mailbox")}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec set_delivery_quarantine(Ecto.UUID.t(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def set_delivery_quarantine(inbound_delivery_id, quarantined?)
      when is_boolean(quarantined?) do
    Repo.transaction(fn ->
      entries =
        MailboxEntry
        |> where(
          [entry],
          entry.inbound_delivery_id == ^inbound_delivery_id and
            entry.quarantined != ^quarantined?
        )
        |> lock("FOR UPDATE")
        |> select([entry], %{id: entry.id, mailbox_id: entry.mailbox_id})
        |> Repo.all()

      entry_ids = Enum.map(entries, & &1.id)

      count =
        if entry_ids == [] do
          0
        else
          {count, _rows} =
            MailboxEntry
            |> where([entry], entry.id in ^entry_ids)
            |> Repo.update_all(set: [quarantined: quarantined?, updated_at: DateTime.utc_now()])

          count
        end

      {count, entries |> Enum.map(& &1.mailbox_id) |> Enum.uniq()}
    end)
    |> case do
      {:ok, {count, mailbox_ids}} ->
        Enum.each(mailbox_ids, &notify_change({:ok, count}, &1))
        {:ok, count}

      {:error, reason} ->
        {:error, database_error(reason)}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  defp maybe_search_threads(query, ""), do: query

  defp maybe_search_threads(query, search) do
    having(
      query,
      [_thread, _entry, message],
      fragment(
        "BOOL_OR(? @@ websearch_to_tsquery('simple', ?))",
        message.search_document,
        ^search
      )
    )
  end

  defp maybe_unread_only(query, false), do: query

  defp maybe_unread_only(query, true) do
    having(query, [_thread, entry, _message], fragment("BOOL_OR(? IS NULL)", entry.read_at))
  end

  defp maybe_after_thread_cursor(query, nil), do: query

  defp maybe_after_thread_cursor(query, cursor) do
    case decode_cursor(cursor) do
      {:ok, at, id} ->
        where(
          query,
          [row],
          row.last_message_at < ^at or
            (row.last_message_at == ^at and row.thread_id < ^id)
        )

      :error ->
        query
    end
  end

  defp maybe_in_folder(query, nil), do: query
  defp maybe_in_folder(query, folder_id), do: where(query, [entry], entry.folder_id == ^folder_id)

  defp summary(rows, metadata) do
    latest = List.first(rows)

    preview =
      latest.text_body |> to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 180)

    %View.ConversationSummary{
      thread_id: latest.thread_id,
      subject: latest.subject || "(No subject)",
      sender_name: latest.sender_name,
      sender_address: latest.sender_address,
      preview: preview,
      last_message_at: metadata.last_message_at,
      message_count: metadata.message_count,
      unread: Enum.any?(rows, &is_nil(&1.read_at)),
      starred: Enum.any?(rows, &(!is_nil(&1.starred_at))),
      attachment_count: 0,
      entry_ids: Enum.map(rows, & &1.entry_id)
    }
  end

  defp add_attachment_counts(items, mailbox_id, folder_id) do
    thread_ids = Enum.map(items, & &1.thread_id)

    counts =
      from(attachment in Attachment,
        join: entry in MailboxEntry,
        on: entry.message_id == attachment.message_id,
        where:
          entry.mailbox_id == ^mailbox_id and entry.folder_id == ^folder_id and
            entry.thread_id in ^thread_ids and not entry.quarantined,
        group_by: entry.thread_id,
        select: {entry.thread_id, count(attachment.id)}
      )
      |> Repo.all()
      |> Map.new()

    Enum.map(items, &%{&1 | attachment_count: Map.get(counts, &1.thread_id, 0)})
  end

  defp message_view(%{entry: entry, message: message}) do
    attachments =
      Attachment
      |> where([attachment], attachment.message_id == ^message.id)
      |> order_by([attachment], asc: attachment.part_path)
      |> Repo.all()
      |> Enum.map(fn attachment ->
        %View.Attachment{
          id: attachment.id,
          filename: attachment.filename || "attachment",
          media_type: attachment.media_type,
          disposition: attachment.disposition,
          size: attachment.size,
          content_id: attachment.content_id
        }
      end)

    %View.Message{
      id: message.id,
      entry_id: entry.id,
      subject: message.subject || "(No subject)",
      sender_name: message.sender_name,
      sender_address: message.sender_address,
      sent_at: message.sent_at,
      received_at: message.received_at || message.sent_at || entry.inserted_at,
      text_body: message.text_body,
      has_html: is_binary(message.sanitized_html),
      read: not is_nil(entry.read_at),
      starred: not is_nil(entry.starred_at),
      attachments: attachments
    }
  end

  defp reply_source(message) do
    addresses =
      MessageAddress
      |> where([address], address.message_id == ^message.id)
      |> order_by([address], asc: address.kind, asc: address.position)
      |> Repo.all()

    sender =
      addresses
      |> Enum.find(&(&1.kind == "from"))
      |> case do
        %MessageAddress{} = address -> address_view(address)
        nil -> %{display_name: message.sender_name, address: message.sender_address}
      end

    %View.ReplySource{
      message_id: message.id,
      rfc_message_id: message.rfc_message_id,
      references: message.references,
      subject: message.subject || "(No subject)",
      sender: sender,
      reply_to: addresses_of_kind(addresses, "reply_to"),
      to: addresses_of_kind(addresses, "to"),
      cc: addresses_of_kind(addresses, "cc"),
      sent_at: message.sent_at || message.inserted_at,
      text_body: message.text_body
    }
  end

  defp addresses_of_kind(addresses, kind) do
    addresses
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(&address_view/1)
  end

  defp address_view(address),
    do: %{display_name: address.display_name, address: address.address}

  defp move_to_system(mailbox_id, entry_ids, kind) do
    with {:ok, _folders} <- Folders.ensure(mailbox_id),
         %Folder{id: folder_id} <- Folders.get_system(mailbox_id, kind) do
      move(mailbox_id, entry_ids, folder_id)
    else
      nil -> {:error, error(:permanent, :not_found, "system folder not found")}
      {:error, reason} -> {:error, database_error(reason)}
    end
  end

  defp update_entries(mailbox_id, entry_ids, changes) do
    {count, _rows} =
      scoped_entries(mailbox_id, entry_ids)
      |> Repo.update_all(set: Keyword.put(changes, :updated_at, DateTime.utc_now()))

    {:ok, count}
    |> notify_change(mailbox_id)
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  defp scoped_entries(mailbox_id, entry_ids) do
    from(entry in MailboxEntry,
      where:
        entry.mailbox_id == ^mailbox_id and entry.id in ^entry_ids and
          not entry.quarantined
    )
  end

  defp notify_change({:ok, count} = result, mailbox_id) do
    :telemetry.execute(
      [:manifold, :mail, :mailbox, :changed],
      %{entry_count: count},
      %{mailbox_id: mailbox_id}
    )

    result
  end

  defp notify_change(error, _mailbox_id), do: error

  defp normalize_transaction({:ok, count}), do: {:ok, count}
  defp normalize_transaction({:error, reason}), do: {:error, database_error(reason)}

  defp encode_cursor(%DateTime{} = at, id) do
    [DateTime.to_iso8601(at), id]
    |> Enum.join("|")
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [at, id] <- String.split(decoded, "|", parts: 2),
         {:ok, datetime, 0} <- DateTime.from_iso8601(at),
         {:ok, _uuid} <- Ecto.UUID.cast(id) do
      {:ok, datetime, id}
    else
      _other -> :error
    end
  end

  defp valid_uuids?(ids), do: Enum.all?(ids, &match?({:ok, _uuid}, Ecto.UUID.cast(&1)))

  defp database_error(reason),
    do:
      error(:temporary, :database_unavailable, "mail database operation failed", %{
        reason: inspect(reason)
      })

  defp storage_error(reason),
    do:
      error(:temporary, :object_store_failed, "attachment storage operation failed", %{
        reason: inspect(reason)
      })

  defp error(class, reason, message, details \\ %{}),
    do: Error.new(class, reason, message, details)
end

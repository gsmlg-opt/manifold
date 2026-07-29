defmodule Manifold.Mail.Projector do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Core.Error
  alias Manifold.Mail.HtmlSanitizer
  alias Manifold.Mail.Folders
  alias Manifold.Mail.{HeaderProjection, InboundSource, ParsedMessage, Parser, ProjectionResult}

  alias Manifold.Mail.Schema.{
    Attachment,
    MailboxEntry,
    Message,
    MessageAddress,
    MessageHeader,
    Thread
  }

  alias Manifold.Repo
  alias Manifold.Storage.{BlobStore, RawStore}

  @spec project(InboundSource.t(), Keyword.t()) ::
          {:ok, ProjectionResult.t()} | {:error, Error.t()}
  def project(%InboundSource{} = source, opts) do
    with {:ok, versions} <- projection_versions(opts),
         {:ok, existing} <- existing_projection(source.inbound_delivery_id) do
      case existing do
        %Message{} = message ->
          if projection_current?(message, versions) do
            result(message)
          else
            project_new(source, versions, opts)
          end

        nil ->
          project_new(source, versions, opts)
      end
    end
  end

  @spec stale_delivery_ids(pos_integer(), pos_integer(), Keyword.t()) :: [Ecto.UUID.t()]
  def stale_delivery_ids(parser_version, sanitizer_version, opts \\ [])

  def stale_delivery_ids(parser_version, sanitizer_version, opts)
      when is_integer(parser_version) and parser_version > 0 and is_integer(sanitizer_version) and
             sanitizer_version > 0 do
    limit = opts |> Keyword.get(:limit, 500) |> min(5_000) |> max(1)

    Message
    |> where(
      [message],
      message.parser_version < ^parser_version or
        message.sanitizer_version < ^sanitizer_version
    )
    |> order_by([message], asc: message.inserted_at, asc: message.id)
    |> select([message], message.inbound_delivery_id)
    |> limit(^limit)
    |> Repo.all()
  end

  def stale_delivery_ids(_parser_version, _sanitizer_version, _opts), do: []

  defp project_new(source, versions, opts) do
    with {:ok, raw} <- read_raw(source, opts),
         {:ok, parsed, parse_state, parse_error} <- parse_or_fallback(raw, opts),
         {:ok, stored_attachments} <- store_attachments(parsed.attachments, opts),
         :ok <- maybe_fault(opts, :after_blob_storage_before_commit),
         {:ok, message} <-
           commit_projection(
             source,
             parsed,
             parse_state,
             parse_error,
             stored_attachments,
             versions
           ),
         {:ok, projection} <- result(message) do
      :telemetry.execute(
        [:manifold, :mail, :projection, :stop],
        %{raw_size: source.raw_size, attachment_count: length(stored_attachments)},
        %{
          inbound_delivery_id: source.inbound_delivery_id,
          message_id: message.id,
          state: parse_state,
          mailbox_ids: projection.mailbox_ids
        }
      )

      {:ok, projection}
    end
  end

  defp existing_projection(delivery_id) do
    {:ok, Repo.get_by(Message, inbound_delivery_id: delivery_id)}
  rescue
    DBConnection.ConnectionError ->
      {:error, error(:temporary, :database_unavailable, "mail database is unavailable")}
  end

  defp read_raw(source, opts) do
    raw_store_opts = Keyword.get(opts, :raw_store_opts, [])

    with {:ok, stat} <- RawStore.stat(source.raw_object_key, raw_store_opts),
         :ok <- verify_stat(stat, source),
         {:ok, io} <- RawStore.open(source.raw_object_key, raw_store_opts) do
      result =
        case IO.binread(io, source.raw_size + 1) do
          raw when is_binary(raw) and byte_size(raw) == source.raw_size -> {:ok, raw}
          raw when is_binary(raw) -> {:error, :raw_size_mismatch}
          {:error, reason} -> {:error, reason}
        end

      close_result = File.close(io)
      combine_close(result, close_result)
    else
      {:error, %Error{}} = failure -> failure
      {:error, reason} -> {:error, storage_error(reason)}
    end
  end

  defp verify_stat(%{size: size, sha256: sha256}, source) do
    if size == source.raw_size and sha256 == source.raw_sha256 do
      :ok
    else
      {:error,
       error(:permanent, :raw_verification_failed, "archived raw message does not match metadata")}
    end
  end

  defp combine_close({:ok, raw}, :ok), do: {:ok, raw}
  defp combine_close({:error, reason}, _close), do: {:error, storage_error(reason)}
  defp combine_close({:ok, _raw}, {:error, reason}), do: {:error, storage_error(reason)}

  defp parse_or_fallback(raw, opts) do
    case isolated_parse(raw, opts) do
      {:ok, %ParsedMessage{} = parsed} ->
        {:ok, parsed, "parsed", nil}

      {:error, %Error{} = parse_error} ->
        {:ok, fallback(raw), "fallback", Atom.to_string(parse_error.reason)}
    end
  end

  defp isolated_parse(raw, opts) do
    timeout =
      Keyword.get(
        opts,
        :parse_timeout_ms,
        Application.get_env(:manifold_mail, :parse_timeout_ms, 30_000)
      )

    max_heap_words =
      Keyword.get(
        opts,
        :parse_max_heap_words,
        Application.get_env(:manifold_mail, :parse_max_heap_words, 16_000_000)
      )

    task =
      Task.Supervisor.async_nolink(Manifold.Mail.TaskSupervisor, fn ->
        Process.flag(:max_heap_size, %{size: max_heap_words, kill: true, error_logger: false})
        Parser.parse(raw, parser_opts(opts))
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, _reason} ->
        {:error, error(:permanent, :parser_terminated, "mail parser terminated")}

      nil ->
        {:error, error(:permanent, :parser_timeout, "mail parser timed out")}
    end
  end

  defp parser_opts(opts) do
    Keyword.take(opts, [
      :max_raw_bytes,
      :max_header_bytes,
      :max_headers,
      :max_mime_depth,
      :max_parts,
      :max_decoded_bytes,
      :max_attachment_bytes
    ])
  end

  defp fallback(raw) do
    headers =
      case HeaderProjection.parse(raw,
             max_header_bytes: Application.get_env(:manifold_mail, :max_header_bytes, 256 * 1024),
             max_headers: Application.get_env(:manifold_mail, :max_headers, 1_000)
           ) do
        {:ok, values} -> values
        {:error, _reason} -> []
      end

    %ParsedMessage{
      subject: header_value(headers, "subject") || "(Unparseable message)",
      rfc_message_id: header_value(headers, "message-id"),
      in_reply_to: header_value(headers, "in-reply-to"),
      references: reference_ids(header_value(headers, "references")),
      headers: headers
    }
  end

  defp store_attachments(attachments, opts) do
    Enum.reduce_while(attachments, {:ok, []}, fn attachment, {:ok, stored} ->
      case store_attachment(attachment, opts) do
        {:ok, value} -> {:cont, {:ok, [value | stored]}}
        {:error, %Error{}} = failure -> {:halt, failure}
      end
    end)
    |> case do
      {:ok, stored} -> {:ok, Enum.reverse(stored)}
      {:error, %Error{}} = failure -> failure
    end
  end

  defp store_attachment(attachment, opts) do
    blob_store_opts = Keyword.get(opts, :blob_store_opts, [])

    with {:ok, key} <- BlobStore.build_key(attachment.sha256),
         {:ok, stat} <-
           with_temporary_attachment(attachment.bytes, fn path ->
             BlobStore.put_from_path(
               key,
               path,
               Keyword.put(blob_store_opts, :expected_size, attachment.size)
             )
           end),
         true <- stat.sha256 == attachment.sha256 and stat.size == attachment.size do
      {:ok, {attachment, key}}
    else
      false ->
        {:error, storage_error(:blob_verification_failed)}

      {:error, %Error{}} = failure ->
        failure

      {:error, reason} ->
        {:error, storage_error(reason)}
    end
  end

  defp with_temporary_attachment(bytes, fun) do
    root = Path.join(System.tmp_dir!(), "manifold-mail-" <> Ecto.UUID.generate())
    path = Path.join(root, "attachment.partial")

    result =
      with :ok <- File.mkdir(root),
           :ok <- File.chmod(root, 0o700),
           :ok <- File.write(path, bytes, [:binary, :exclusive]),
           :ok <- File.chmod(path, 0o600) do
        fun.(path)
      end

    case File.rm_rf(root) do
      {:ok, _paths} -> result
      {:error, reason, _path} -> {:error, {:temporary_cleanup_failed, reason}}
    end
  end

  defp commit_projection(
         source,
         parsed,
         parse_state,
         parse_error,
         stored_attachments,
         versions
       ) do
    result =
      Repo.transaction(fn ->
        advisory_lock("delivery:" <> source.inbound_delivery_id)

        case Repo.get_by(Message, inbound_delivery_id: source.inbound_delivery_id) do
          %Message{} = existing ->
            if projection_current?(existing, versions) do
              existing
            else
              lock_delivery_mailboxes(source.inbound_delivery_id)

              replace_projection(
                existing,
                source,
                parsed,
                parse_state,
                parse_error,
                stored_attachments,
                versions
              )
            end

          nil ->
            lock_delivery_mailboxes(source.inbound_delivery_id)

            persist_projection(
              source,
              parsed,
              parse_state,
              parse_error,
              stored_attachments,
              versions
            )
        end
      end)

    normalize_projection_transaction(result)
  rescue
    DBConnection.ConnectionError ->
      {:error, error(:temporary, :database_unavailable, "mail database is unavailable")}
  end

  defp persist_projection(
         source,
         parsed,
         parse_state,
         parse_error,
         stored_attachments,
         versions
       ) do
    attrs = message_attrs(source, parsed, parse_state, parse_error, versions)

    with {:ok, message} <- Message.changeset(%Message{}, attrs) |> Repo.insert(),
         {_count, _rows} <- insert_headers(message.id, parsed.headers),
         {_count, _rows} <- insert_addresses(message.id, parsed),
         {_count, _rows} <- insert_attachments(message.id, stored_attachments),
         :ok <- finalize_mailboxes(message, source, parsed) do
      message
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp replace_projection(
         existing,
         source,
         parsed,
         parse_state,
         parse_error,
         stored_attachments,
         versions
       ) do
    attrs =
      message_attrs(
        source,
        parsed,
        parse_state,
        parse_error,
        monotonic_versions(existing, versions)
      )

    with {:ok, message} <- Message.changeset(existing, attrs) |> Repo.update(),
         {_count, _rows} <-
           Repo.delete_all(from(header in MessageHeader, where: header.message_id == ^message.id)),
         {_count, _rows} <-
           Repo.delete_all(
             from(address in MessageAddress, where: address.message_id == ^message.id)
           ),
         {_count, _rows} <-
           Repo.delete_all(
             from(attachment in Attachment, where: attachment.message_id == ^message.id)
           ),
         {_count, _rows} <- insert_headers(message.id, parsed.headers),
         {_count, _rows} <- insert_addresses(message.id, parsed),
         {_count, _rows} <- insert_attachments(message.id, stored_attachments),
         :ok <- refresh_message_threads(message.id) do
      message
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp message_attrs(source, parsed, parse_state, parse_error, versions) do
    sender = List.first(parsed.from)

    %{
      inbound_delivery_id: source.inbound_delivery_id,
      rfc_message_id: clean_message_id(parsed.rfc_message_id),
      in_reply_to: clean_message_id(parsed.in_reply_to),
      references: Enum.map(parsed.references, &clean_message_id/1),
      subject: clean_text(parsed.subject),
      sender_name: sender && clean_text(sender.name),
      sender_address: sender && clean_text(sender.address),
      sent_at: parsed.sent_at,
      text_body: clean_text(parsed.text_body),
      sanitized_html: parsed.html_body |> clean_text() |> HtmlSanitizer.sanitize(),
      parser_version: versions.parser_version,
      sanitizer_version: versions.sanitizer_version,
      parse_state: parse_state,
      parse_error: parse_error
    }
  end

  defp insert_headers(message_id, headers) do
    now = DateTime.utc_now()

    rows =
      Enum.map(headers, fn header ->
        %{
          id: Ecto.UUID.generate(),
          message_id: message_id,
          position: header.position,
          original_name: clean_text(header.original_name),
          normalized_name: clean_text(header.normalized_name),
          unfolded_value: clean_text(header.value),
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(MessageHeader, rows)
  end

  defp insert_addresses(message_id, parsed) do
    now = DateTime.utc_now()

    rows =
      [:from, :sender, :reply_to, :to, :cc, :bcc]
      |> Enum.flat_map(fn kind ->
        parsed
        |> Map.fetch!(kind)
        |> Enum.with_index()
        |> Enum.map(fn {address, position} ->
          %{
            id: Ecto.UUID.generate(),
            message_id: message_id,
            kind: Atom.to_string(kind),
            position: position,
            display_name: clean_text(address.name),
            address: clean_text(address.address),
            canonical_address: address.address |> clean_text() |> canonical_header_address(),
            inserted_at: now,
            updated_at: now
          }
        end)
      end)

    Repo.insert_all(MessageAddress, rows)
  end

  defp insert_attachments(message_id, attachments) do
    now = DateTime.utc_now()

    rows =
      Enum.map(attachments, fn {attachment, key} ->
        %{
          id: Ecto.UUID.generate(),
          message_id: message_id,
          part_path: attachment.part_path,
          content_id: clean_text(attachment.content_id),
          filename: clean_text(attachment.filename),
          media_type: clean_text(attachment.media_type),
          disposition: attachment.disposition,
          size: attachment.size,
          sha256: attachment.sha256,
          object_key: key,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(Attachment, rows)
  end

  defp finalize_mailboxes(message, source, parsed) do
    entries =
      MailboxEntry
      |> where([entry], entry.inbound_delivery_id == ^source.inbound_delivery_id)
      |> order_by([entry], asc: entry.mailbox_id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      with {:ok, folders} <- ensure_system_folders(entry.mailbox_id),
           {:ok, thread} <- find_or_create_thread(entry.mailbox_id, message, source, parsed),
           {:ok, _entry} <-
             entry
             |> MailboxEntry.changeset(%{
               message_id: message.id,
               folder_id: folders.inbox.id,
               thread_id: thread.id
             })
             |> Repo.update(),
           :ok <- refresh_thread(thread.id) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_system_folders(mailbox_id) do
    Folders.ensure(mailbox_id)
  end

  defp find_or_create_thread(mailbox_id, message, source, parsed) do
    candidates =
      [parsed.in_reply_to | Enum.reverse(parsed.references)]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    existing_thread =
      if candidates == [] do
        nil
      else
        matches =
          from(entry in MailboxEntry,
            join: existing_message in Message,
            on: existing_message.id == entry.message_id,
            where:
              entry.mailbox_id == ^mailbox_id and
                existing_message.rfc_message_id in ^candidates and
                not is_nil(entry.thread_id),
            order_by: [
              asc: existing_message.inserted_at,
              asc: entry.inserted_at,
              asc: entry.id
            ],
            select: {existing_message.rfc_message_id, entry.thread_id}
          )
          |> Repo.all()
          |> Enum.reduce(%{}, fn {message_id, thread_id}, acc ->
            Map.put_new(acc, message_id, thread_id)
          end)

        Enum.find_value(candidates, &Map.get(matches, &1))
      end

    case existing_thread && Repo.get(Thread, existing_thread) do
      %Thread{} = thread ->
        {:ok, thread}

      nil ->
        Thread.changeset(%Thread{}, %{
          mailbox_id: mailbox_id,
          subject_summary: thread_subject(message.subject),
          last_message_at: message.sent_at || source.received_at,
          message_count: 0
        })
        |> Repo.insert()
    end
  end

  defp refresh_thread(thread_id) do
    %{count: count, last_message_at: last_message_at} =
      from(entry in MailboxEntry,
        join: message in Message,
        on: message.id == entry.message_id,
        where: entry.thread_id == ^thread_id,
        select: %{
          count: count(entry.id),
          last_message_at: max(fragment("COALESCE(?, ?)", message.sent_at, entry.inserted_at))
        }
      )
      |> Repo.one!()

    thread = Repo.get!(Thread, thread_id)

    case Thread.changeset(thread, %{message_count: count, last_message_at: last_message_at})
         |> Repo.update() do
      {:ok, _thread} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_message_threads(message_id) do
    MailboxEntry
    |> where([entry], entry.message_id == ^message_id and not is_nil(entry.thread_id))
    |> select([entry], entry.thread_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.reduce_while(:ok, fn thread_id, :ok ->
      case refresh_thread(thread_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp result(%Message{} = message) do
    mailbox_ids =
      MailboxEntry
      |> where([entry], entry.message_id == ^message.id)
      |> order_by([entry], asc: entry.mailbox_id)
      |> select([entry], entry.mailbox_id)
      |> Repo.all()

    state = if message.parse_state == "fallback", do: :fallback, else: :parsed

    {:ok,
     %ProjectionResult{
       message_id: message.id,
       state: state,
       mailbox_ids: mailbox_ids,
       parser_version: message.parser_version,
       sanitizer_version: message.sanitizer_version
     }}
  end

  defp lock_delivery_mailboxes(delivery_id) do
    MailboxEntry
    |> where([entry], entry.inbound_delivery_id == ^delivery_id)
    |> order_by([entry], asc: entry.mailbox_id)
    |> select([entry], entry.mailbox_id)
    |> Repo.all()
    |> Enum.each(&advisory_lock("mailbox:" <> &1))
  end

  defp advisory_lock(lock_key) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      [lock_key]
    )
  end

  defp normalize_projection_transaction({:ok, %Message{} = message}), do: {:ok, message}
  defp normalize_projection_transaction({:error, %Error{} = error}), do: {:error, error}

  defp normalize_projection_transaction({:error, %Ecto.Changeset{} = changeset}) do
    {:error,
     error(
       :permanent,
       :invalid_projection,
       "message projection did not satisfy persistence rules",
       %{
         errors: inspect(changeset.errors)
       }
     )}
  end

  defp normalize_projection_transaction({:error, reason}) do
    {:error,
     error(:temporary, :database_unavailable, "mail projection transaction failed", %{
       reason: inspect(reason)
     })}
  end

  defp projection_versions(opts) do
    parser_version =
      Keyword.get(opts, :parser_version, Application.get_env(:manifold_mail, :parser_version, 1))

    sanitizer_version =
      Keyword.get(
        opts,
        :sanitizer_version,
        Application.get_env(:manifold_mail, :sanitizer_version, 1)
      )

    if valid_version?(parser_version) and valid_version?(sanitizer_version) do
      {:ok, %{parser_version: parser_version, sanitizer_version: sanitizer_version}}
    else
      {:error,
       error(
         :permanent,
         :invalid_projection_version,
         "projection versions must be positive integers"
       )}
    end
  end

  defp projection_current?(message, versions) do
    is_integer(message.parser_version) and is_integer(message.sanitizer_version) and
      message.parser_version >= versions.parser_version and
      message.sanitizer_version >= versions.sanitizer_version
  end

  defp monotonic_versions(message, requested) do
    %{
      parser_version: max(message.parser_version || 0, requested.parser_version),
      sanitizer_version: max(message.sanitizer_version || 0, requested.sanitizer_version)
    }
  end

  defp valid_version?(version), do: is_integer(version) and version > 0

  defp thread_subject(nil), do: nil
  defp thread_subject(subject), do: String.slice(subject, 0, 998)

  defp canonical_header_address(address) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [local, domain] -> String.downcase(local) <> "@" <> String.downcase(domain)
      _other -> String.downcase(address)
    end
  end

  defp clean_text(nil), do: nil
  defp clean_text(value) when is_binary(value), do: String.replace(value, <<0>>, "")

  defp clean_message_id(nil), do: nil
  defp clean_message_id(value), do: value |> clean_text() |> String.slice(0, 998)

  defp header_value(headers, name) do
    headers
    |> Enum.find(&(&1.normalized_name == name))
    |> case do
      nil -> nil
      header -> header.value
    end
  end

  defp reference_ids(nil), do: []

  defp reference_ids(value) do
    case Regex.scan(~r/<[^>]+>/, value) |> List.flatten() do
      [] -> String.split(value, ~r/\s+/, trim: true)
      ids -> ids
    end
  end

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, error(:temporary, point, "injected projection failure")}
    else
      :ok
    end
  end

  defp storage_error(reason),
    do:
      error(:temporary, :object_store_failed, "mail object storage failed", %{
        reason: inspect(reason)
      })

  defp error(class, reason, message, details \\ %{}),
    do: Error.new(class, reason, message, details)
end

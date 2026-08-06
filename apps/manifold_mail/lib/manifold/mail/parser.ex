defmodule Manifold.Mail.Parser do
  @moduledoc """
  Bounded MIME parsing boundary for immutable RFC 5322 source messages.
  """

  alias Mail.Message
  alias Manifold.Core.Error
  alias Manifold.Mail.{Charset, HeaderProjection, ParsedMessage}
  alias Manifold.Mail.ParsedMessage.Attachment

  @type result :: {:ok, ParsedMessage.t()} | {:error, Error.t()}

  @spec parse(binary(), Keyword.t()) :: result()
  def parse(raw, opts \\ [])

  def parse(raw, opts) when is_binary(raw) do
    limits = limits(opts)

    with :ok <- check_size(byte_size(raw), limits.max_raw_bytes, :raw_too_large),
         {:ok, headers} <-
           HeaderProjection.parse(raw,
             max_header_bytes: limits.max_header_bytes,
             max_headers: limits.max_headers
           ),
         {:ok, message} <- parse_mail(normalize_lines(raw)),
         {:ok, leaves} <- collect_leaves(message, limits),
         :ok <- check_decoded_size(leaves, limits.max_decoded_bytes),
         {:ok, attachments} <- attachments(leaves, limits.max_attachment_bytes) do
      {:ok, build_projection(message, headers, attachments)}
    end
  end

  def parse(_raw, _opts),
    do: {:error, error(:invalid_message, "raw message must be a binary")}

  defp limits(opts) do
    config = Application.get_all_env(:manifold_mail)

    %{
      max_raw_bytes: value(opts, config, :max_raw_bytes, 100 * 1024 * 1024),
      max_header_bytes: value(opts, config, :max_header_bytes, 256 * 1024),
      max_headers: value(opts, config, :max_headers, 1_000),
      max_mime_depth: value(opts, config, :max_mime_depth, 20),
      max_parts: value(opts, config, :max_parts, 500),
      max_decoded_bytes: value(opts, config, :max_decoded_bytes, 100 * 1024 * 1024),
      max_attachment_bytes: value(opts, config, :max_attachment_bytes, 50 * 1024 * 1024)
    }
  end

  defp value(opts, config, key, default),
    do: Keyword.get(opts, key, Keyword.get(config, key, default))

  defp parse_mail(raw) do
    normalized = normalize_unlabeled_header_bytes(raw)

    message =
      Mail.Parsers.RFC2822.parse(normalized,
        charset_handler: &Charset.decode/2
      )

    if malformed_multipart?(message) do
      {:error, error(:malformed_mime, "multipart message has no valid boundary parts")}
    else
      {:ok, message}
    end
  rescue
    _error in [ArgumentError, CaseClauseError, FunctionClauseError, MatchError] ->
      {:error, error(:malformed_mime, "message MIME structure could not be parsed")}
  end

  # Chinese MUAs often emit raw GBK in Subject/From without RFC 2047. The mail
  # library walks headers as UTF-8 codepoints and crashes on those bytes; rewrite
  # unlabeled 8-bit header lines to UTF-8 before MIME parse.
  defp normalize_unlabeled_header_bytes(raw) do
    case :binary.match(raw, ["\r\n\r\n", "\n\n"]) do
      {index, length} ->
        headers = binary_part(raw, 0, index)
        separator_and_body = binary_part(raw, index, byte_size(raw) - index)

        if String.valid?(headers) do
          raw
        else
          normalize_header_block(headers, length) <> separator_and_body
        end

      :nomatch ->
        raw
    end
  end

  defp normalize_header_block(headers, sep_length) do
    line_sep = if sep_length == 4, do: "\r\n", else: "\n"

    headers
    |> :binary.split([line_sep], [:global])
    |> Enum.map_join(line_sep, &Charset.ensure_utf8/1)
  end

  defp malformed_multipart?(%Message{multipart: false} = message) do
    String.starts_with?(content_type(message), "multipart/")
  end

  defp malformed_multipart?(_message), do: false

  defp collect_leaves(%Message{multipart: false} = message, limits) do
    check_size(1, limits.max_parts, :too_many_parts)
    |> case do
      :ok -> {:ok, [%{message: message, path: "1"}]}
      {:error, %Error{}} = failure -> failure
    end
  end

  defp collect_leaves(%Message{} = message, limits) do
    case walk_indexed_parts(message.parts, [], 1, 0, [], limits) do
      {:ok, leaves, _count} -> {:ok, Enum.reverse(leaves)}
      {:error, %Error{}} = failure -> failure
    end
  end

  defp walk_part(%Message{multipart: true} = part, path, depth, count, leaves, limits) do
    walk_indexed_parts(part.parts, path, depth + 1, count, leaves, limits)
  end

  defp walk_part(%Message{} = part, path, _depth, count, leaves, _limits) do
    {:ok, [%{message: part, path: Enum.join(path, ".")} | leaves], count}
  end

  defp walk_indexed_parts(parts, path, depth, count, leaves, limits) do
    parts
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, leaves, count}, fn {part, index}, {:ok, acc, part_count} ->
      next_count = part_count + 1

      result =
        with :ok <- check_size(depth, limits.max_mime_depth, :mime_too_deep),
             :ok <- check_size(next_count, limits.max_parts, :too_many_parts) do
          walk_part(part, path ++ [index], depth, next_count, acc, limits)
        end

      case result do
        {:ok, new_acc, new_count} -> {:cont, {:ok, new_acc, new_count}}
        {:error, %Error{}} = failure -> {:halt, failure}
      end
    end)
  end

  defp check_decoded_size(leaves, max_bytes) do
    decoded_bytes =
      Enum.reduce(leaves, 0, fn %{message: message}, total ->
        total + body_size(message.body)
      end)

    check_size(decoded_bytes, max_bytes, :decoded_content_too_large)
  end

  defp attachments(leaves, max_attachment_bytes) do
    leaves
    |> Enum.reduce_while({:ok, []}, fn leaf, {:ok, acc} ->
      if attachment?(leaf.message) do
        bytes = body(leaf.message)

        case check_size(byte_size(bytes), max_attachment_bytes, :attachment_too_large) do
          :ok -> {:cont, {:ok, [build_attachment(leaf, bytes) | acc]}}
          {:error, %Error{}} = failure -> {:halt, failure}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, %Error{}} = failure -> failure
    end
  end

  defp build_projection(message, headers, attachments) do
    %{text_body: text_body, html_body: html_body} = selected_bodies(message)

    %ParsedMessage{
      subject: binary_header(message, "subject"),
      rfc_message_id: binary_header(message, "message-id"),
      in_reply_to: binary_header(message, "in-reply-to"),
      references: reference_ids(binary_header(message, "references")),
      sent_at: datetime_header(message, "date"),
      from: addresses(message, "from"),
      sender: addresses(message, "sender"),
      reply_to: addresses(message, "reply-to"),
      to: addresses(message, "to"),
      cc: addresses(message, "cc"),
      bcc: addresses(message, "bcc"),
      headers: headers,
      text_body: text_body,
      html_body: html_body,
      attachments: attachments
    }
  end

  defp selected_bodies(%Message{multipart: true} = message) do
    if attachment?(message) do
      empty_bodies()
    else
      case content_type(message) do
        "multipart/alternative" -> alternative_bodies(message.parts)
        "multipart/related" -> related_bodies(message)
        _other -> first_body_branch(message.parts)
      end
    end
  end

  defp selected_bodies(%Message{} = message) do
    if attachment?(message) do
      empty_bodies()
    else
      case content_type(message) do
        "text/plain" -> %{text_body: normalized_body(message), html_body: nil}
        "text/html" -> %{text_body: nil, html_body: normalized_body(message)}
        _other -> empty_bodies()
      end
    end
  end

  defp alternative_bodies(parts) do
    Enum.reduce(parts, empty_bodies(), fn part, selected ->
      merge_alternative(selected, selected_bodies(part))
    end)
  end

  defp merge_alternative(selected, alternative) do
    %{
      text_body: alternative.text_body || selected.text_body,
      html_body: alternative.html_body || selected.html_body
    }
  end

  defp related_bodies(message) do
    message
    |> related_root()
    |> case do
      nil -> empty_bodies()
      root -> selected_bodies(root)
    end
  end

  defp related_root(message) do
    start = parameter(Message.get_content_type(message), "start")

    if is_binary(start) do
      expected = normalize_content_id(start)

      Enum.find(message.parts, fn part ->
        normalize_content_id(binary_header(part, "content-id")) == expected
      end) || List.first(message.parts)
    else
      List.first(message.parts)
    end
  end

  defp normalize_content_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading("<")
    |> String.trim_trailing(">")
  end

  defp normalize_content_id(_value), do: nil

  defp first_body_branch(parts) do
    Enum.find_value(parts, empty_bodies(), fn part ->
      bodies = selected_bodies(part)

      if has_body?(bodies), do: bodies
    end)
  end

  defp has_body?(%{text_body: text_body, html_body: html_body}),
    do: not is_nil(text_body) or not is_nil(html_body)

  defp empty_bodies, do: %{text_body: nil, html_body: nil}

  defp normalized_body(message), do: message |> body() |> String.trim_trailing()

  defp build_attachment(%{message: message, path: path}, bytes) do
    digest = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    %Attachment{
      part_path: path,
      content_id: binary_header(message, "content-id"),
      filename: filename(message),
      media_type: content_type(message),
      disposition: disposition(message),
      bytes: bytes,
      size: byte_size(bytes),
      sha256: digest
    }
  end

  defp attachment?(message) do
    disposition(message) in ["attachment", "inline"] or not is_nil(filename(message))
  end

  defp content_type(message) do
    case Message.get_content_type(message) do
      [type | _params] when is_binary(type) and type != "" -> String.downcase(type)
      _other -> "text/plain"
    end
  end

  defp disposition(message) do
    case Message.get_header(message, "content-disposition") do
      [value | _params] when value in ["attachment", "inline"] -> value
      value when value in ["attachment", "inline"] -> value
      _other -> "unspecified"
    end
  end

  defp filename(message) do
    parameter(Message.get_header(message, "content-disposition"), "filename") ||
      parameter(Message.get_content_type(message), "name")
  end

  defp parameter([_value | params], key) do
    Enum.find_value(params, fn
      {^key, value} when is_binary(value) -> value
      _other -> nil
    end)
  end

  defp parameter(_value, _key), do: nil

  defp addresses(message, key) do
    message
    |> Message.get_header(key)
    |> List.wrap()
    |> Enum.flat_map(&address_values/1)
  end

  defp address_values({_name, address} = mailbox) when is_binary(address),
    do: normalize_mailboxes([mailbox])

  defp address_values(value) when is_binary(value) do
    value
    |> Mail.Parsers.RFC2822.parse_recipient_value()
    |> normalize_mailboxes()
  end

  defp address_values(_value), do: []

  defp normalize_mailboxes(mailboxes) do
    Enum.flat_map(mailboxes, fn
      {name, address} when is_binary(address) ->
        [%{name: blank_to_nil(name), address: String.trim(address)}]

      address when is_binary(address) ->
        [%{name: nil, address: String.trim(address)}]

      _other ->
        []
    end)
  end

  defp reference_ids(nil), do: []

  defp reference_ids(value) do
    case Regex.scan(~r/<[^>]+>/, value) |> List.flatten() do
      [] -> String.split(value, ~r/\s+/, trim: true)
      ids -> ids
    end
  end

  defp binary_header(message, key) do
    case Message.get_header(message, key) do
      value when is_binary(value) -> String.trim(value)
      _other -> nil
    end
  end

  defp datetime_header(message, key) do
    case Message.get_header(message, key) do
      %DateTime{} = datetime ->
        ensure_usec(datetime)

      value when is_binary(value) ->
        parse_datetime(value)

      _other ->
        nil
    end
  end

  @doc false
  def parse_datetime(value) when is_binary(value) do
    case Mail.Parsers.RFC2822.to_datetime(String.trim(value)) do
      %DateTime{} = datetime -> ensure_usec(datetime)
      {:error, _reason} -> nil
      _other -> nil
    end
  end

  def parse_datetime(_value), do: nil

  defp ensure_usec(%DateTime{microsecond: {us, _}} = datetime),
    do: %{datetime | microsecond: {us, 6}}

  defp body(%Message{body: body}) when is_binary(body), do: body
  defp body(_message), do: ""

  defp body_size(body) when is_binary(body), do: byte_size(body)
  defp body_size(_body), do: 0

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      name -> name
    end
  end

  defp blank_to_nil(_value), do: nil

  defp normalize_lines(raw) do
    if String.contains?(raw, "\r\n") do
      raw
    else
      String.replace(raw, "\n", "\r\n")
    end
  end

  defp check_size(actual, maximum, _reason) when actual <= maximum, do: :ok

  defp check_size(_actual, _maximum, reason),
    do: {:error, error(reason, "message limit exceeded")}

  defp error(reason, message), do: Error.new(:permanent, reason, message)
end

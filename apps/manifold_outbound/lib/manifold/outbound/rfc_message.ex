defmodule Manifold.Outbound.RfcMessage do
  @moduledoc false

  alias Manifold.Core.{Address, Error}
  alias Manifold.Outbound.Provider.Envelope

  @encoded_word_bytes 39
  @soft_header_line_bytes 78
  @hard_header_line_bytes 998

  @spec render(Envelope.t(), Keyword.t()) :: {:ok, binary()} | {:error, Error.t()}
  def render(%Envelope{} = envelope, opts) when is_list(opts) do
    with {:ok, provider} <- provider(opts),
         {:ok, message_id} <- required_message_id(opts),
         {:ok, date} <- required_date(opts),
         {:ok, from} <- mailbox(envelope.from),
         {:ok, to} <- mailbox_list(envelope.to),
         {:ok, cc} <- mailbox_list(envelope.cc),
         {:ok, bcc} <- mailbox_list(envelope.bcc),
         {:ok, subject} <- encoded_subject(envelope.subject),
         {:ok, in_reply_to} <- optional_message_id(envelope.in_reply_to),
         {:ok, references} <- references(envelope.references),
         {:ok, body} <- encoded_body(envelope.text) do
      headers =
        []
        |> add_header("From", from)
        |> add_address_header("To", to)
        |> add_address_header("Cc", cc)
        |> maybe_add_bcc(provider, bcc)
        |> add_header("Subject", subject)
        |> add_header("Date", format_date(date))
        |> add_header("Message-ID", message_id)
        |> maybe_add_header("In-Reply-To", in_reply_to)
        |> maybe_add_references(references)
        |> add_header("MIME-Version", "1.0")
        |> add_header("Content-Type", "text/plain; charset=UTF-8")
        |> add_header("Content-Transfer-Encoding", "quoted-printable")

      headers = headers |> Enum.reverse() |> IO.iodata_to_binary()

      with :ok <- validate_header_lines(headers) do
        {:ok, IO.iodata_to_binary([headers, "\r\n", body])}
      end
    end
  end

  def render(_envelope, _opts), do: invalid()

  @spec render!(Envelope.t(), Keyword.t()) :: binary()
  def render!(envelope, opts) do
    case render(envelope, opts) do
      {:ok, raw} -> raw
      {:error, %Error{message: message}} -> raise ArgumentError, message
    end
  end

  defp provider(opts) do
    case Keyword.get(opts, :provider) do
      provider when provider in [:gmail, :smtp] -> {:ok, provider}
      _invalid -> invalid()
    end
  end

  defp required_message_id(opts) do
    case Keyword.fetch(opts, :message_id) do
      {:ok, value} -> message_id(value)
      :error -> invalid()
    end
  end

  defp required_date(opts) do
    case Keyword.fetch(opts, :date) do
      {:ok, %DateTime{} = date} -> {:ok, date}
      _missing_or_invalid -> invalid()
    end
  end

  defp mailbox_list(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, mailboxes} ->
      case mailbox(value) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | mailboxes]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, mailboxes} -> {:ok, Enum.reverse(mailboxes)}
      error -> error
    end
  end

  defp mailbox_list(_values), do: invalid()

  defp mailbox(value) when is_binary(value) do
    if safe_header?(value) do
      parse_mailbox(String.trim(value))
    else
      invalid()
    end
  end

  defp mailbox(_value), do: invalid()

  defp parse_mailbox(value) do
    case Regex.run(~r/\A(.*)<([^<>]+)>\z/u, value, capture: :all_but_first) do
      [display_name, address] ->
        display_name = String.trim(display_name)

        with false <- String.contains?(display_name, ["<", ">"]),
             {:ok, parsed} <- Address.parse(address),
             {:ok, display_name} <- display_name(display_name) do
          {:ok, format_mailbox(display_name, parsed.original)}
        else
          _invalid -> invalid()
        end

      nil ->
        case Address.parse(value) do
          {:ok, parsed} -> {:ok, parsed.original}
          _invalid -> invalid()
        end
    end
  end

  defp display_name(""), do: {:ok, nil}

  defp display_name(value) do
    if safe_header?(value), do: {:ok, value}, else: invalid()
  end

  defp format_mailbox(nil, address), do: address

  defp format_mailbox(display_name, address) do
    rendered_name =
      if ascii?(display_name) do
        escaped = display_name |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
        "\"#{escaped}\""
      else
        encode_words(display_name)
      end

    "#{rendered_name} <#{address}>"
  end

  defp encoded_subject(subject) when is_binary(subject) do
    if safe_header?(subject), do: {:ok, encode_words(subject)}, else: invalid()
  end

  defp encoded_subject(_subject), do: invalid()

  defp encode_words(""), do: ""

  defp encode_words(value) do
    value
    |> String.codepoints()
    |> Enum.reduce({[], ""}, fn grapheme, {chunks, chunk} ->
      if chunk == "" or byte_size(chunk) + byte_size(grapheme) <= @encoded_word_bytes do
        {chunks, chunk <> grapheme}
      else
        {[chunk | chunks], grapheme}
      end
    end)
    |> then(fn {chunks, chunk} -> Enum.reverse([chunk | chunks]) end)
    |> Enum.map_join("\r\n ", fn chunk -> "=?UTF-8?B?#{Base.encode64(chunk)}?=" end)
  end

  defp optional_message_id(value) when value in [nil, ""], do: {:ok, nil}
  defp optional_message_id(value), do: message_id(value)

  defp message_id(value) when is_binary(value) do
    with true <- safe_header?(value),
         true <- ascii?(value),
         {:ok, id_left, id_right} <- split_message_id(value),
         true <- dot_atom?(id_left),
         true <- dot_atom?(id_right) do
      {:ok, value}
    else
      _invalid -> invalid()
    end
  end

  defp message_id(_value), do: invalid()

  defp split_message_id("<" <> rest) do
    if String.ends_with?(rest, ">") do
      inner = binary_part(rest, 0, byte_size(rest) - 1)

      case String.split(inner, "@", parts: 3) do
        [id_left, id_right] -> {:ok, id_left, id_right}
        _invalid -> :error
      end
    else
      :error
    end
  end

  defp split_message_id(_value), do: :error

  defp dot_atom?(value) do
    value != "" and
      value
      |> String.split(".", trim: false)
      |> Enum.all?(fn
        "" -> false
        atom -> atom |> :binary.bin_to_list() |> Enum.all?(&atext?/1)
      end)
  end

  defp atext?(byte) when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9, do: true
  defp atext?(byte) when byte in ~c"!#$%&'*+-/=?^_`{|}~", do: true
  defp atext?(_byte), do: false

  defp references(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, ids} ->
      case message_id(value) do
        {:ok, id} when byte_size(id) < @hard_header_line_bytes ->
          {:cont, {:ok, [id | ids]}}

        {:ok, _oversized} ->
          {:halt, invalid()}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp references(_values), do: invalid()

  defp encoded_body(body) when is_binary(body) do
    if String.valid?(body) do
      encoded =
        body
        |> normalize_newlines()
        |> String.split("\n", trim: false)
        |> Enum.map_join("\r\n", &quoted_printable_line/1)

      cond do
        encoded == "" -> {:ok, ""}
        String.ends_with?(encoded, "\r\n") -> {:ok, encoded}
        true -> {:ok, encoded <> "\r\n"}
      end
    else
      invalid()
    end
  end

  defp encoded_body(_body), do: invalid()

  defp normalize_newlines(body) do
    body
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  defp quoted_printable_line(line) do
    bytes = :binary.bin_to_list(line)
    last_index = length(bytes) - 1

    bytes
    |> Enum.with_index()
    |> Enum.map(fn {byte, index} -> quoted_printable_byte(byte, index == last_index) end)
    |> wrap_quoted_printable()
  end

  defp quoted_printable_byte(byte, trailing?) do
    if byte in 33..60 or byte in 62..126 or (byte in [9, 32] and not trailing?) do
      <<byte>>
    else
      "=" <> Base.encode16(<<byte>>)
    end
  end

  defp wrap_quoted_printable(tokens) do
    {lines, line} =
      Enum.reduce(tokens, {[], ""}, fn token, {lines, line} ->
        if byte_size(line) + byte_size(token) > 75 do
          {[line <> "=" | lines], token}
        else
          {lines, line <> token}
        end
      end)

    [line | lines]
    |> Enum.reverse()
    |> Enum.join("\r\n")
  end

  defp format_date(date), do: Calendar.strftime(date, "%a, %d %b %Y %H:%M:%S %z")

  defp add_address_header(headers, _name, []), do: headers

  defp add_address_header(headers, name, values),
    do: add_header(headers, name, Enum.join(values, ", "))

  defp maybe_add_bcc(headers, :gmail, values), do: add_address_header(headers, "Bcc", values)
  defp maybe_add_bcc(headers, :smtp, _values), do: headers

  defp maybe_add_header(headers, _name, nil), do: headers
  defp maybe_add_header(headers, name, value), do: add_header(headers, name, value)

  defp maybe_add_references(headers, []), do: headers

  defp maybe_add_references(headers, references) do
    [fold_references(references) | headers]
  end

  defp fold_references([first | rest]) do
    {lines, line} =
      Enum.reduce([first | rest], {[], "References:"}, fn reference, {lines, line} ->
        candidate = line <> " " <> reference

        if byte_size(candidate) <= @soft_header_line_bytes do
          {lines, candidate}
        else
          {[line | lines], " " <> reference}
        end
      end)

    [line | lines]
    |> Enum.reverse()
    |> Enum.intersperse("\r\n")
    |> Kernel.++(["\r\n"])
  end

  defp add_header(headers, name, value), do: [[name, ": ", value, "\r\n"] | headers]

  defp validate_header_lines(headers) do
    if headers
       |> String.split("\r\n", trim: false)
       |> Enum.all?(&(byte_size(&1) <= @hard_header_line_bytes)) do
      :ok
    else
      invalid()
    end
  end

  defp safe_header?(value) do
    String.valid?(value) and
      value
      |> :binary.bin_to_list()
      |> Enum.all?(&(&1 not in 0..31 and &1 != 127))
  end

  defp ascii?(value), do: String.to_charlist(value) |> Enum.all?(&(&1 in 1..127))

  defp invalid do
    {:error,
     Error.new(
       :permanent,
       :invalid_rfc_message,
       "outbound message contains an invalid RFC field"
     )}
  end
end

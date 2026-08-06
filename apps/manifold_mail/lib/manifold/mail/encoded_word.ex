defmodule Manifold.Mail.EncodedWord do
  @moduledoc false

  alias Manifold.Mail.Charset

  @doc """
  Decodes RFC 2047 encoded-words in a header value using `Charset.decode/2`.
  """
  @spec decode(nil | String.t()) :: nil | String.t()
  def decode(nil), do: nil
  def decode(value) when is_binary(value), do: decode_words(value)

  defp decode_words(""), do: ""

  defp decode_words(<<"=?", rest::binary>>) do
    case split_encoded_word(rest) do
      {:ok, charset, encoding, data, remainder} ->
        decoded =
          data
          |> decode_payload(encoding)
          |> then(&Charset.decode(charset, &1))

        remainder = strip_encoded_word_separator(remainder)
        decoded <> decode_words(remainder)

      :error ->
        "=?" <> decode_words(rest)
    end
  end

  defp decode_words(<<char::utf8, rest::binary>>),
    do: <<char::utf8, decode_words(rest)::binary>>

  defp split_encoded_word(value) do
    with [charset, rest] <- String.split(value, "?", parts: 2),
         [encoding, rest] <- String.split(rest, "?", parts: 2),
         [data, remainder] <- String.split(rest, "?=", parts: 2),
         encoding when encoding in ["B", "b", "Q", "q"] <- encoding do
      {:ok, charset, encoding, data, remainder}
    else
      _ -> :error
    end
  end

  defp decode_payload(data, encoding) when encoding in ["B", "b"] do
    case Base.decode64(String.replace(data, ~r/\s+/, "")) do
      {:ok, decoded} -> decoded
      :error -> data
    end
  end

  defp decode_payload(data, encoding) when encoding in ["Q", "q"] do
    data
    |> String.replace("_", " ")
    |> Mail.Encoders.QuotedPrintable.decode()
  end

  # RFC 2047: linear whitespace between adjacent encoded-words is removed.
  defp strip_encoded_word_separator(<<" ", rest::binary>>),
    do: strip_encoded_word_separator(rest)

  defp strip_encoded_word_separator(<<"\t", rest::binary>>),
    do: strip_encoded_word_separator(rest)

  defp strip_encoded_word_separator(rest), do: rest
end

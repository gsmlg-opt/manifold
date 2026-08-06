defmodule Manifold.Mail.HeaderProjection do
  @moduledoc false

  alias Manifold.Core.Error
  alias Manifold.Mail.Charset

  @field_name ~r/\A[!-9;-~]+\z/

  @spec parse(binary(), Keyword.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def parse(raw, opts) when is_binary(raw) do
    max_bytes = Keyword.fetch!(opts, :max_header_bytes)
    max_headers = Keyword.fetch!(opts, :max_headers)

    with {:ok, header_block} <- header_block(raw),
         :ok <- within_limit(byte_size(header_block), max_bytes, :headers_too_large),
         {:ok, headers} <- parse_lines(split_lines(header_block)),
         :ok <- within_limit(length(headers), max_headers, :too_many_headers) do
      {:ok,
       headers
       |> Enum.with_index()
       |> Enum.map(fn {{name, value}, position} ->
         %{
           position: position,
           original_name: utf8(name),
           normalized_name: String.downcase(name),
           value: value |> utf8() |> String.trim()
         }
       end)}
    end
  end

  defp header_block(raw) do
    case :binary.match(raw, ["\r\n\r\n", "\n\n"]) do
      {index, _length} -> {:ok, binary_part(raw, 0, index)}
      :nomatch -> {:error, error(:invalid_headers, "message has no header/body separator")}
    end
  end

  defp split_lines(block), do: String.split(block, ~r/\r?\n/, trim: false)

  defp parse_lines(lines) do
    lines
    |> Enum.reduce_while({:ok, []}, fn
      <<first, _rest::binary>> = continuation, {:ok, [previous | headers]}
      when first in [?\s, ?\t] ->
        {name, value} = previous
        unfolded = value <> " " <> String.trim_leading(continuation)
        {:cont, {:ok, [{name, unfolded} | headers]}}

      <<first, _rest::binary>>, {:ok, []} when first in [?\s, ?\t] ->
        {:halt, {:error, error(:invalid_headers, "header continuation has no field")}}

      line, {:ok, headers} ->
        case parse_line(line) do
          {:ok, header} -> {:cont, {:ok, [header | headers]}}
          {:error, %Error{}} = failure -> {:halt, failure}
        end
    end)
    |> case do
      {:ok, []} -> {:error, error(:invalid_headers, "message has no headers")}
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      {:error, %Error{}} = failure -> failure
    end
  end

  defp parse_line(line) do
    case :binary.split(line, ":", [:global]) do
      [name | value_parts] when value_parts != [] ->
        if Regex.match?(@field_name, name) do
          {:ok, {name, value_parts |> Enum.join(":") |> String.trim_leading()}}
        else
          {:error, error(:invalid_headers, "message contains an invalid header field name")}
        end

      _other ->
        {:error, error(:invalid_headers, "message contains a malformed header")}
    end
  end

  defp within_limit(value, limit, _reason) when value <= limit, do: :ok
  defp within_limit(_value, _limit, reason), do: {:error, error(reason, "header limit exceeded")}

  defp utf8(binary), do: Charset.ensure_utf8(binary)

  defp error(reason, message), do: Error.new(:permanent, reason, message)
end

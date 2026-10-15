defmodule Manifold.Core.HTTPClient.ContentDecoder do
  @moduledoc false

  # safeInflate emits bounded output batches, so a small compressed entity cannot
  # force allocation of its full decoded size before the application limit runs.
  def decode(headers, body, limit) do
    encodings =
      headers
      |> Map.get("content-encoding", [])
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(String.trim(&1) |> String.downcase()))

    if body == "" or encodings == [] or
         not Enum.all?(encodings, &(&1 in ["gzip", "deflate", "identity"])) do
      {:ok, body, headers}
    else
      result =
        encodings
        |> Enum.reverse()
        |> Enum.reduce_while({:ok, body}, fn encoding, {:ok, bytes} ->
          case inflate(bytes, encoding, limit) do
            {:ok, decoded} -> {:cont, {:ok, decoded}}
            error -> {:halt, error}
          end
        end)

      case result do
        {:ok, decoded} ->
          {:ok, decoded, Map.drop(headers, ["content-encoding", "content-length"])}

        error ->
          error
      end
    end
  end

  defp inflate(body, "identity", _limit), do: {:ok, body}

  defp inflate(body, encoding, limit) do
    zlib = :zlib.open()

    try do
      :ok =
        :zlib.inflateInit(
          zlib,
          if(encoding == "gzip", do: 31, else: 15),
          if(encoding == "gzip", do: :reset, else: :error)
        )

      with {:ok, chunks} <- drain(zlib, body, [], 0, limit),
           :ok <- :zlib.inflateEnd(zlib) do
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      end
    catch
      :error, _ -> {:error, :invalid_content_encoding}
    after
      :zlib.close(zlib)
    end
  end

  defp drain(zlib, input, chunks, size, limit) do
    {status, output} = :zlib.safeInflate(zlib, input)
    size = size + IO.iodata_length(output)

    cond do
      limit != :infinity and size > limit -> {:error, :response_limit}
      status == :finished -> {:ok, [output | chunks]}
      status == :continue -> drain(zlib, [], [output | chunks], size, limit)
    end
  end
end

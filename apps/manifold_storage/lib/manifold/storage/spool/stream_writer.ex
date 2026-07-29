defmodule Manifold.Storage.Spool.StreamWriter do
  @moduledoc false

  alias Manifold.Core.Error
  alias Manifold.Storage.Filesystem

  @type stat :: %{raw_size: non_neg_integer(), raw_sha256: String.t()}

  @spec write(Path.t(), Enumerable.t(), non_neg_integer(), Keyword.t()) ::
          {:ok, stat()} | {:error, Error.t()}
  def write(path, stream, max_bytes, opts) do
    with {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      result =
        with :ok <- Filesystem.chmod(path, 0o600, opts),
             {:ok, stat} <- write_chunks(io, stream, max_bytes, opts),
             :ok <- Filesystem.sync_file(io, opts) do
          {:ok, stat}
        end

      close_with_result(io, result)
    else
      {:error, reason} -> {:error, spool_error(reason)}
    end
  end

  defp write_chunks(io, stream, max_bytes, opts) do
    initial = %{raw_size: 0, hash: :crypto.hash_init(:sha256)}

    try do
      Enum.reduce_while(stream, {:ok, initial}, fn item, {:ok, stat} ->
        with {:ok, chunk} <- normalize_chunk(item),
             :ok <- enforce_max_bytes(stat.raw_size, byte_size(chunk), max_bytes),
             :ok <- Filesystem.write(io, chunk, opts) do
          {:cont,
           {:ok,
            %{
              raw_size: stat.raw_size + byte_size(chunk),
              hash: :crypto.hash_update(stat.hash, chunk)
            }}}
        else
          {:error, %Error{} = error} -> {:halt, {:error, error}}
          {:error, reason} -> {:halt, {:error, spool_error(reason)}}
        end
      end)
      |> finalize_hash()
    rescue
      error in [File.Error, ErlangError, RuntimeError] ->
        {:error, spool_error(Exception.message(error))}
    end
  end

  defp normalize_chunk(chunk) when is_binary(chunk), do: {:ok, chunk}
  defp normalize_chunk({:ok, chunk}) when is_binary(chunk), do: {:ok, chunk}
  defp normalize_chunk({:error, reason}), do: {:error, reason}
  defp normalize_chunk(other), do: {:error, {:invalid_stream_chunk, other}}

  defp enforce_max_bytes(current_size, chunk_size, max_bytes)
       when current_size + chunk_size <= max_bytes,
       do: :ok

  defp enforce_max_bytes(_current_size, _chunk_size, _max_bytes) do
    {:error, Error.new(:permanent, :message_too_large, "message exceeds spool limit")}
  end

  defp finalize_hash({:ok, %{raw_size: raw_size, hash: hash}}) do
    {:ok,
     %{
       raw_size: raw_size,
       raw_sha256: hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
     }}
  end

  defp finalize_hash({:error, %Error{} = error}), do: {:error, error}

  defp close_with_result(io, result) do
    close_result = File.close(io)

    case result do
      {:ok, stat} ->
        case close_result do
          :ok -> {:ok, stat}
          {:error, reason} -> {:error, spool_error(reason)}
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp spool_error(reason) do
    Error.new(:temporary, :spool_failed, "spool write failed", %{reason: inspect(reason)})
  end
end

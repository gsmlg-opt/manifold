defmodule Manifold.Storage.Filesystem do
  @moduledoc false

  @unsupported_directory_sync_errors [:einval, :eisdir, :enotsup, :eopnotsupp]

  @spec ensure_private_directory(Path.t(), Keyword.t()) :: :ok | {:error, term()}
  def ensure_private_directory(path, opts) do
    with :ok <- File.mkdir_p(path),
         :ok <- chmod(path, 0o700, opts) do
      :ok
    end
  end

  @spec chmod(Path.t(), non_neg_integer(), Keyword.t()) :: :ok | {:error, term()}
  def chmod(path, mode, opts) do
    opts
    |> Keyword.get(:chmod_fun, &File.chmod/2)
    |> then(& &1.(path, mode))
    |> normalize_result()
  end

  @spec write(File.io_device(), iodata(), Keyword.t()) :: :ok | {:error, term()}
  def write(io, data, opts) do
    opts
    |> Keyword.get(:write_fun, &IO.binwrite/2)
    |> then(& &1.(io, data))
    |> normalize_result()
  end

  @spec sync_file(File.io_device(), Keyword.t()) :: :ok | {:error, term()}
  def sync_file(io, opts) do
    opts
    |> Keyword.get(:file_sync_fun, &:file.sync/1)
    |> then(& &1.(io))
    |> normalize_result()
  end

  @spec sync_directory(Path.t(), Keyword.t()) :: :ok | {:error, term()}
  def sync_directory(path, opts) do
    result =
      case Keyword.fetch(opts, :dir_sync_fun) do
        {:ok, sync_fun} -> sync_fun.(path)
        :error -> sync_directory(path)
      end

    case normalize_result(result) do
      {:error, reason} when reason in @unsupported_directory_sync_errors -> :ok
      result -> result
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw]) do
      {:ok, io} ->
        io
        |> :file.sync()
        |> close_with_result(io)

      {:error, _reason} = error ->
        error
    end
  end

  defp close_with_result(result, io) do
    close_result = normalize_result(:file.close(io))

    case normalize_result(result) do
      :ok -> close_result
      {:error, _reason} = error -> error
    end
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:error, _reason} = error), do: error
  defp normalize_result(other), do: {:error, {:unexpected_filesystem_result, other}}
end

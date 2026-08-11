defmodule Manifold.Storage.RawStore.Local do
  @moduledoc """
  Local filesystem raw-message store.
  """

  @behaviour Manifold.Storage.RawStore

  alias Manifold.Storage.Filesystem
  alias Manifold.Storage.Spool.Manifest

  @impl true
  def put_from_path(%{root: root}, key, source_path, opts) do
    with :ok <- validate_key(key),
         destination = Path.join(root, key),
         temporary = temporary_path(destination) do
      result =
        with :ok <- Filesystem.ensure_private_directory(Path.dirname(destination), opts),
             :ok <- maybe_fault(opts, :before_copy),
             :ok <- copy_to_temporary(source_path, temporary, opts),
             :ok <- Filesystem.chmod(temporary, 0o600, opts),
             :ok <- maybe_fault(opts, :after_copy),
             :ok <- sync_file(temporary, opts),
             :ok <- File.rename(temporary, destination),
             :ok <- Filesystem.sync_directory(Path.dirname(destination), opts),
             {:ok, stat} <- stat(%{root: root}, key, opts) do
          {:ok, stat}
        end

      cleanup_temporary(temporary, result)
    end
  end

  @impl true
  def open(%{root: root}, key, _opts) do
    with :ok <- validate_key(key) do
      File.open(Path.join(root, key), [:read, :binary])
    end
  end

  @impl true
  def stat(%{root: root}, key, _opts) do
    with :ok <- validate_key(key),
         path = Path.join(root, key),
         {:ok, file_stat} <- File.stat(path),
         {:ok, sha256} <- Manifest.sha256_file(path) do
      {:ok, %{size: file_stat.size, sha256: sha256}}
    end
  end

  @impl true
  def delete(%{root: root}, key, _opts) do
    with :ok <- validate_key(key) do
      case File.rm(Path.join(root, key)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_key(key) when is_binary(key) do
    cond do
      Path.type(key) != :relative -> {:error, :invalid_key}
      String.contains?(key, ["..", "\\"]) -> {:error, :invalid_key}
      true -> :ok
    end
  end

  defp validate_key(_key), do: {:error, :invalid_key}

  defp copy_to_temporary(source_path, temporary, opts) do
    copy_fun = Keyword.get(opts, :copy_fun, &File.copy/2)

    case copy_fun.(source_path, temporary) do
      {:ok, _bytes} -> :ok
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:unexpected_copy_result, other}}
    end
  end

  defp sync_file(path, opts) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      result = Filesystem.sync_file(io, opts)
      close_with_result(io, result)
    end
  end

  defp close_with_result(io, result) do
    close_result = File.close(io)

    case result do
      :ok -> close_result
      {:error, _reason} = error -> error
    end
  end

  defp cleanup_temporary(temporary, result) do
    case File.rm(temporary) do
      :ok -> result
      {:error, :enoent} -> result
      {:error, reason} -> {:error, {:temporary_cleanup_failed, reason}}
    end
  end

  defp temporary_path(destination) do
    suffix = System.unique_integer([:monotonic, :positive])
    destination <> ".partial-" <> Integer.to_string(suffix)
  end

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, point}
    else
      :ok
    end
  end
end

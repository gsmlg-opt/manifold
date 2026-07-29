defmodule Manifold.Storage.BlobStore.Local do
  @moduledoc """
  Local filesystem adapter for content-addressed attachment blobs.
  """

  @behaviour Manifold.Storage.BlobStore

  alias Manifold.Storage.BlobStore
  alias Manifold.Storage.Filesystem
  alias Manifold.Storage.Spool.Manifest

  @impl true
  def put_from_path(%{root: root}, key, source_path, opts) do
    with {:ok, expected_sha256} <- BlobStore.digest_from_key(key),
         {:ok, expected_size} <- expected_size(opts),
         destination = Path.join(root, key),
         temporary = temporary_path(destination) do
      result =
        with :ok <- ensure_private_path(root, key, opts),
             :ok <- maybe_fault(opts, :before_copy),
             :ok <- copy_to_temporary(source_path, temporary, opts),
             :ok <- Filesystem.chmod(temporary, 0o600, opts),
             :ok <- maybe_fault(opts, :after_copy),
             :ok <- sync_file(temporary, opts),
             {:ok, stat} <- stat_path(temporary),
             :ok <- verify_sha256(stat, expected_sha256),
             :ok <- verify_size(stat, expected_size),
             :ok <- maybe_fault(opts, :before_rename),
             {:ok, committed_stat} <-
               commit_temporary(%{root: root}, key, temporary, stat, opts) do
          {:ok, committed_stat}
        end

      cleanup_temporary(temporary, result)
    end
  end

  @impl true
  def open(%{root: root}, key, _opts) do
    with {:ok, _digest} <- BlobStore.digest_from_key(key) do
      File.open(Path.join(root, key), [:read, :binary])
    end
  end

  @impl true
  def stat(%{root: root}, key, _opts) do
    with {:ok, expected_sha256} <- BlobStore.digest_from_key(key),
         {:ok, stat} <- stat_path(Path.join(root, key)),
         :ok <- verify_sha256(stat, expected_sha256) do
      {:ok, stat}
    end
  end

  @impl true
  def delete(%{root: root}, key, opts) do
    with {:ok, _digest} <- BlobStore.digest_from_key(key),
         path = Path.join(root, key),
         :ok <- File.rm(path),
         :ok <- Filesystem.sync_directory(Path.dirname(path), opts) do
      :ok
    end
  end

  defp expected_size(opts) do
    case Keyword.fetch(opts, :expected_size) do
      {:ok, size} when is_integer(size) and size >= 0 -> {:ok, size}
      {:ok, _invalid} -> {:error, :invalid_expected_size}
      :error -> {:error, :expected_size_required}
    end
  end

  defp ensure_private_path(root, key, opts) do
    root = Path.expand(root)

    with :ok <- ensure_private_directory(root, opts) do
      key
      |> Path.dirname()
      |> Path.split()
      |> Enum.reduce_while({:ok, root}, fn component, {:ok, parent} ->
        path = Path.join(parent, component)

        case ensure_private_directory(path, opts) do
          :ok -> {:cont, {:ok, path}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, _path} -> :ok
        {:error, _reason} = error -> error
      end
    end
  end

  defp ensure_private_directory(path, opts) do
    existed? = File.dir?(path)

    with :ok <- Filesystem.ensure_private_directory(path, opts),
         :ok <- sync_created_directory_parent(path, existed?, opts) do
      :ok
    end
  end

  defp sync_created_directory_parent(_path, true, _opts), do: :ok

  defp sync_created_directory_parent(path, false, opts) do
    Filesystem.sync_directory(Path.dirname(path), opts)
  end

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

  defp stat_path(path) do
    with {:ok, file_stat} <- File.stat(path),
         {:ok, sha256} <- Manifest.sha256_file(path) do
      {:ok, %{size: file_stat.size, sha256: sha256}}
    end
  end

  defp verify_sha256(%{sha256: expected}, expected), do: :ok

  defp verify_sha256(%{sha256: actual}, expected) do
    {:error, {:sha256_mismatch, %{expected: expected, actual: actual}}}
  end

  defp verify_size(%{size: expected}, expected), do: :ok

  defp verify_size(%{size: actual}, expected) do
    {:error, {:size_mismatch, %{expected: expected, actual: actual}}}
  end

  defp commit_temporary(config, key, temporary, stat, opts) do
    destination = Path.join(config.root, key)

    case stat(config, key, opts) do
      {:ok, ^stat} ->
        with :ok <- File.rm(temporary),
             :ok <- Filesystem.sync_directory(Path.dirname(destination), opts) do
          {:ok, stat}
        end

      {:ok, _different} ->
        replace_temporary(temporary, destination, stat, opts)

      {:error, :enoent} ->
        replace_temporary(temporary, destination, stat, opts)

      {:error, {:sha256_mismatch, _details}} ->
        replace_temporary(temporary, destination, stat, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp replace_temporary(temporary, destination, stat, opts) do
    with :ok <- File.rename(temporary, destination),
         :ok <- Filesystem.sync_directory(Path.dirname(destination), opts) do
      {:ok, stat}
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

defmodule Manifold.Storage.RawStore.Local do
  @moduledoc """
  Local filesystem raw-message store.
  """

  @behaviour Manifold.Storage.RawStore

  alias Manifold.Storage.Spool.Manifest

  @impl true
  def put_from_path(%{root: root}, key, source_path, opts) do
    with :ok <- validate_key(key),
         destination = Path.join(root, key),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- maybe_fault(opts, :before_copy),
         {:ok, _bytes} <- File.copy(source_path, destination),
         :ok <- maybe_fault(opts, :after_copy),
         :ok <- sync_file(destination),
         :ok <- sync_dir(Path.dirname(destination)),
         {:ok, stat} <- stat(%{root: root}, key, opts) do
      {:ok, stat}
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
      File.rm(Path.join(root, key))
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

  defp sync_file(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        :file.sync(io)
      after
        File.close(io)
      end
    end
  end

  defp sync_dir(path) do
    case :file.open(String.to_charlist(path), [:read, :raw]) do
      {:ok, io} ->
        try do
          case :file.sync(io) do
            :ok -> :ok
            {:error, _reason} -> :ok
          end
        after
          :file.close(io)
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, point}
    else
      :ok
    end
  end
end

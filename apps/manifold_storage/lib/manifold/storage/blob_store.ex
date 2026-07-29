defmodule Manifold.Storage.BlobStore do
  @moduledoc """
  Content-addressed attachment blob-store boundary.

  Blob keys are derived only from a lowercase hexadecimal SHA-256 digest. The
  original attachment filename and other message-controlled values never take
  part in key construction.
  """

  @type key :: String.t()
  @type sha256 :: String.t()
  @type stat :: %{size: non_neg_integer(), sha256: sha256()}

  @callback put_from_path(map(), key(), Path.t(), Keyword.t()) ::
              {:ok, stat()} | {:error, term()}
  @callback open(map(), key(), Keyword.t()) :: {:ok, File.io_device()} | {:error, term()}
  @callback stat(map(), key(), Keyword.t()) :: {:ok, stat()} | {:error, term()}
  @callback delete(map(), key(), Keyword.t()) :: :ok | {:error, term()}

  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @key_pattern ~r/\Ablobs\/sha256\/([0-9a-f]{2})\/([0-9a-f]{64})\z/

  @doc """
  Builds the canonical object key for a trusted SHA-256 digest.
  """
  @spec build_key(sha256()) :: {:ok, key()} | {:error, :invalid_sha256}
  def build_key(sha256) when is_binary(sha256) do
    if Regex.match?(@sha256_pattern, sha256) do
      {:ok, "blobs/sha256/#{binary_part(sha256, 0, 2)}/#{sha256}"}
    else
      {:error, :invalid_sha256}
    end
  end

  def build_key(_sha256), do: {:error, :invalid_sha256}

  @doc false
  @spec digest_from_key(term()) :: {:ok, sha256()} | {:error, :invalid_key}
  def digest_from_key(key) when is_binary(key) do
    case Regex.run(@key_pattern, key, capture: :all_but_first) do
      [prefix, digest] when prefix == binary_part(digest, 0, 2) -> {:ok, digest}
      _other -> {:error, :invalid_key}
    end
  end

  def digest_from_key(_key), do: {:error, :invalid_key}

  @spec put_from_path(key(), Path.t(), Keyword.t()) :: {:ok, stat()} | {:error, term()}
  def put_from_path(key, source_path, opts \\ []) do
    {adapter, config, adapter_opts} = adapter_call(opts)
    adapter.put_from_path(config, key, source_path, adapter_opts)
  end

  @spec open(key(), Keyword.t()) :: {:ok, File.io_device()} | {:error, term()}
  def open(key, opts \\ []) do
    {adapter, config, adapter_opts} = adapter_call(opts)
    adapter.open(config, key, adapter_opts)
  end

  @spec stat(key(), Keyword.t()) :: {:ok, stat()} | {:error, term()}
  def stat(key, opts \\ []) do
    {adapter, config, adapter_opts} = adapter_call(opts)
    adapter.stat(config, key, adapter_opts)
  end

  @spec delete(key(), Keyword.t()) :: :ok | {:error, term()}
  def delete(key, opts \\ []) do
    {adapter, config, adapter_opts} = adapter_call(opts)
    adapter.delete(config, key, adapter_opts)
  end

  defp adapter_call(opts) do
    adapter =
      Keyword.get(
        opts,
        :backend,
        Application.get_env(
          :manifold_storage,
          :blob_store_backend,
          Manifold.Storage.BlobStore.Local
        )
      )

    root =
      Keyword.get(opts, :root) ||
        Application.get_env(:manifold_storage, :blob_store_dir) ||
        Application.fetch_env!(:manifold_storage, :raw_store_dir)

    {adapter, %{root: root}, Keyword.drop(opts, [:backend, :root])}
  end
end

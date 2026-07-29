defmodule Manifold.Storage.Spool do
  @moduledoc """
  Durable local filesystem spool.
  """

  alias Manifold.Core.{Error, ID}
  alias Manifold.Storage.Filesystem
  alias Manifold.Storage.Spool.{Bundle, Manifest, StreamWriter}

  @required_dirs ~w(tmp ready failed quarantine)

  @type write_attrs :: %{
          required(:peer_ip) => String.t(),
          required(:received_at) => DateTime.t(),
          optional(:ingest_id) => String.t(),
          optional(:helo) => String.t() | nil,
          optional(:envelope_from) => String.t() | nil,
          optional(:original_recipients) => [String.t()],
          optional(:routes) => [map()]
        }

  @type stream_chunk :: binary() | {:ok, binary()} | {:error, term()}

  @spec write_bundle(binary(), write_attrs(), Keyword.t()) ::
          {:ok, Bundle.t()} | {:error, Error.t()}
  def write_bundle(raw, attrs, opts \\ []) when is_binary(raw) and is_map(attrs) do
    root = Keyword.get(opts, :root, spool_root())
    min_free_bytes = Keyword.get(opts, :min_free_bytes, configured_min_free_bytes())
    ingest_id = Keyword.get(opts, :ingest_id, Map.get(attrs, :ingest_id, ID.generate()))

    with :ok <- validate_ingest_id(ingest_id),
         :ok <- ensure_layout(root, opts),
         :ok <- ensure_capacity(root, min_free_bytes, byte_size(raw), opts),
         :ok <- maybe_fault(opts, :before_partial_create),
         {:ok, bundle} <-
           write_partial_then_ready(
             root,
             ingest_id,
             raw,
             Map.put(attrs, :ingest_id, ingest_id),
             opts
           ) do
      :telemetry.execute([:manifold, :spool, :write, :stop], %{raw_size: byte_size(raw)}, %{
        ingest_id: ingest_id
      })

      {:ok, bundle}
    end
  end

  @doc """
  Writes a bounded enumerable of binary chunks into a durable spool bundle.

  `:max_bytes` is required. Stream items may be binaries, `{:ok, binary}`, or
  `{:error, reason}`. The latter stops the write and removes the partial bundle.
  """
  @spec write_bundle_from_stream(Enumerable.t(), write_attrs(), Keyword.t()) ::
          {:ok, Bundle.t()} | {:error, Error.t()}
  def write_bundle_from_stream(stream, attrs, opts \\ []) when is_map(attrs) do
    root = Keyword.get(opts, :root, spool_root())
    min_free_bytes = Keyword.get(opts, :min_free_bytes, configured_min_free_bytes())
    ingest_id = Keyword.get(opts, :ingest_id, Map.get(attrs, :ingest_id, ID.generate()))
    max_bytes = Keyword.get(opts, :max_bytes)

    with :ok <- validate_ingest_id(ingest_id),
         :ok <- validate_max_bytes(max_bytes),
         :ok <- ensure_layout(root, opts),
         :ok <- ensure_capacity(root, min_free_bytes, max_bytes, opts),
         :ok <- maybe_fault(opts, :before_partial_create),
         {:ok, bundle} <-
           write_stream_partial_then_ready(
             root,
             ingest_id,
             stream,
             Map.put(attrs, :ingest_id, ingest_id),
             max_bytes,
             opts
           ) do
      :telemetry.execute(
        [:manifold, :spool, :write, :stop],
        %{raw_size: bundle.manifest.raw_size},
        %{ingest_id: ingest_id}
      )

      {:ok, bundle}
    end
  end

  @spec read_manifest(Path.t()) :: {:ok, Manifest.t()} | {:error, term()}
  def read_manifest(bundle_path) do
    bundle_path
    |> Path.join("manifest.json")
    |> File.read()
    |> case do
      {:ok, json} -> Manifest.decode(json)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec bundle_for(Path.t(), String.t()) :: Bundle.t()
  def bundle_for(root, ingest_id) do
    path = Path.join([root, "ready", ingest_id])

    %Bundle{
      ingest_id: ingest_id,
      root: root,
      path: path,
      raw_path: Path.join(path, "raw.eml"),
      manifest_path: Path.join(path, "manifest.json")
    }
  end

  @spec ready_bundle_paths(Path.t()) :: [Path.t()]
  def ready_bundle_paths(root \\ spool_root()) do
    root
    |> Path.join("ready")
    |> File.ls()
    |> case do
      {:ok, entries} ->
        entries
        |> Enum.filter(&ID.safe_path_id?/1)
        |> Enum.map(&Path.join([root, "ready", &1]))
        |> Enum.filter(&File.dir?/1)

      {:error, _reason} ->
        []
    end
  end

  @spec cleanup_partials(Path.t(), non_neg_integer()) :: :ok
  def cleanup_partials(root \\ spool_root(), older_than_seconds \\ 3600) do
    cutoff = System.system_time(:second) - older_than_seconds

    root
    |> Path.join("tmp")
    |> File.ls()
    |> case do
      {:ok, entries} ->
        Enum.each(entries, fn entry ->
          path = Path.join([root, "tmp", entry])

          with true <- String.ends_with?(entry, ".partial"),
               {:ok, stat} <- File.stat(path, time: :posix),
               true <- stat.mtime <= cutoff do
            File.rm_rf(path)
          end
        end)

      {:error, _reason} ->
        :ok
    end

    :ok
  end

  @spec move_ready_to_failed(String.t(), String.t()) :: {:ok, Path.t()} | {:error, term()}
  def move_ready_to_failed(ingest_id, reason),
    do: move_ready_to_failed(spool_root(), ingest_id, reason)

  @spec move_ready_to_failed(Path.t(), String.t(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def move_ready_to_failed(root, ingest_id, reason) do
    with :ok <- validate_ingest_id(ingest_id) do
      source = Path.join([root, "ready", ingest_id])
      timestamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond) |> Integer.to_string()
      destination = Path.join([root, "failed", reason <> "-" <> ingest_id <> "-" <> timestamp])

      case File.rename(source, destination) do
        :ok -> {:ok, destination}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec remove_ready_bundle(Path.t()) :: :ok | {:error, term()}
  def remove_ready_bundle(path) do
    case File.rm_rf(path) do
      {:ok, _files} -> :ok
      {:error, reason, _file} -> {:error, reason}
    end
  end

  @doc """
  Atomically moves a ready bundle out of the delivery namespace before removal.

  A cleanup interrupted after the rename leaves a deterministic tombstone in
  `quarantine/` that a later call can remove without re-verifying deleted files.
  """
  @spec cleanup_ready_bundle(Path.t(), keyword()) :: :ok | {:error, term()}
  def cleanup_ready_bundle(path, opts \\ []) do
    ingest_id = Path.basename(path)
    root = path |> Path.dirname() |> Path.dirname()
    expected_path = Path.join([root, "ready", ingest_id])
    tombstone_path = Path.join([root, "quarantine", "cleanup-" <> ingest_id])

    with :ok <- validate_ingest_id(ingest_id),
         true <- Path.expand(path) == Path.expand(expected_path) do
      case File.stat(path) do
        {:ok, %{type: :directory}} ->
          with :ok <- remove_cleanup_tombstone(tombstone_path, opts),
               :ok <- File.rename(path, tombstone_path),
               :ok <- Filesystem.sync_directory(Path.join(root, "ready"), opts),
               :ok <- Filesystem.sync_directory(Path.join(root, "quarantine"), opts),
               :ok <- maybe_fault(opts, :after_cleanup_rename),
               :ok <- remove_cleanup_tombstone(tombstone_path, opts) do
            :ok
          end

        {:error, :enoent} ->
          resume_cleanup_tombstone(root, tombstone_path, opts)

        {:error, reason} ->
          {:error, reason}

        {:ok, _not_directory} ->
          {:error, :enotdir}
      end
    else
      false -> {:error, :invalid_ready_bundle_path}
      {:error, _reason} = failure -> failure
    end
  end

  @spec classify_ready_orphan(Path.t(), non_neg_integer()) ::
          :orphan_retained | :orphan_expired | :invalid
  def classify_ready_orphan(bundle_path, retention_seconds) do
    with ingest_id when is_binary(ingest_id) <- Path.basename(bundle_path),
         true <- ID.safe_path_id?(ingest_id),
         {:ok, stat} <- File.stat(bundle_path, time: :posix) do
      if stat.mtime <= System.system_time(:second) - retention_seconds do
        :orphan_expired
      else
        :orphan_retained
      end
    else
      _ -> :invalid
    end
  end

  @spec spool_root() :: Path.t()
  def spool_root, do: Application.fetch_env!(:manifold_storage, :spool_dir)

  defp write_partial_then_ready(root, ingest_id, raw, attrs, opts) do
    tmp_path = Path.join([root, "tmp", ingest_id <> ".partial"])
    ready_path = Path.join([root, "ready", ingest_id])
    manifest = Manifest.build(attrs, raw)
    raw_path = Path.join(tmp_path, "raw.eml")

    with :ok <- Filesystem.ensure_private_directory(tmp_path, opts),
         :ok <- write_synced(raw_path, raw, opts) do
      finish_bundle(root, ingest_id, tmp_path, ready_path, manifest, opts)
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:temporary, :spool_failed, "spool write failed", %{reason: inspect(reason)})}
    end
  end

  defp write_stream_partial_then_ready(root, ingest_id, stream, attrs, max_bytes, opts) do
    tmp_path = Path.join([root, "tmp", ingest_id <> ".partial"])
    ready_path = Path.join([root, "ready", ingest_id])
    raw_path = Path.join(tmp_path, "raw.eml")

    with :ok <- Filesystem.ensure_private_directory(tmp_path, opts) do
      case StreamWriter.write(raw_path, stream, max_bytes, opts) do
        {:ok, %{raw_size: raw_size, raw_sha256: raw_sha256}} ->
          manifest = Manifest.build_from_stat(attrs, raw_size, raw_sha256)
          finish_bundle(root, ingest_id, tmp_path, ready_path, manifest, opts)

        {:error, %Error{} = error} ->
          remove_partial(tmp_path)
          {:error, error}
      end
    else
      {:error, reason} ->
        {:error, spool_error(reason)}
    end
  end

  defp finish_bundle(root, ingest_id, tmp_path, ready_path, manifest, opts) do
    manifest_path = Path.join(tmp_path, "manifest.json")

    with :ok <- write_synced(manifest_path, Jason.encode!(manifest), opts),
         :ok <- Filesystem.sync_directory(tmp_path, opts),
         :ok <- Filesystem.sync_directory(Path.join(root, "tmp"), opts),
         :ok <- maybe_fault(opts, :before_ready_rename),
         :ok <- File.rename(tmp_path, ready_path),
         :ok <- Filesystem.sync_directory(Path.join(root, "ready"), opts),
         :ok <- maybe_fault(opts, :after_ready_rename) do
      {:ok,
       %Bundle{
         ingest_id: ingest_id,
         root: root,
         path: ready_path,
         raw_path: Path.join(ready_path, "raw.eml"),
         manifest_path: Path.join(ready_path, "manifest.json"),
         manifest: manifest
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, spool_error(reason)}
    end
  end

  defp remove_partial(path) do
    File.rm_rf(path)
    :ok
  end

  defp write_synced(path, data, opts) do
    with {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      result =
        with :ok <- Filesystem.chmod(path, 0o600, opts),
             :ok <- Filesystem.write(io, data, opts),
             :ok <- Filesystem.sync_file(io, opts) do
          :ok
        end

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

  defp ensure_layout(root, opts) do
    Enum.reduce_while(@required_dirs, :ok, fn dir, :ok ->
      case Filesystem.ensure_private_directory(Path.join(root, dir), opts) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            Error.new(:temporary, :spool_failed, "spool layout failed", %{reason: inspect(reason)})}}
      end
    end)
  end

  defp ensure_capacity(root, min_free_bytes, raw_size, opts) do
    free_bytes_fun = Keyword.get(opts, :free_bytes_fun, &free_bytes/1)

    case free_bytes_fun.(root) do
      {:ok, free_bytes} when free_bytes >= min_free_bytes + raw_size ->
        :ok

      {:ok, _free_bytes} ->
        {:error,
         Error.new(:capacity, :insufficient_spool_capacity, "insufficient spool capacity")}

      {:error, reason} ->
        {:error,
         Error.new(:temporary, :spool_failed, "spool capacity check failed", %{
           reason: inspect(reason)
         })}
    end
  end

  defp free_bytes(path) do
    path = Path.expand(path)
    {output, 0} = System.cmd("df", ["-Pk", path])

    output
    |> String.split("\n", trim: true)
    |> List.last()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.at(3)
    |> case do
      nil -> {:error, :unparseable_df}
      blocks -> {:ok, String.to_integer(blocks) * 1024}
    end
  rescue
    _ -> {:error, :df_failed}
  end

  defp configured_min_free_bytes,
    do: Application.get_env(:manifold_storage, :spool_min_free_bytes, 0)

  defp validate_max_bytes(max_bytes) when is_integer(max_bytes) and max_bytes >= 0, do: :ok

  defp validate_max_bytes(_max_bytes) do
    {:error, Error.new(:permanent, :spool_failed, "max_bytes must be a non-negative integer")}
  end

  defp validate_ingest_id(ingest_id) do
    if ID.safe_path_id?(ingest_id) do
      :ok
    else
      {:error, Error.new(:permanent, :spool_failed, "invalid internal ingest id")}
    end
  end

  defp remove_cleanup_tombstone(path, opts) do
    case File.stat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, _stat} ->
        result =
          opts
          |> Keyword.get(:cleanup_remove_fun, &File.rm_rf/1)
          |> then(& &1.(path))

        case result do
          {:ok, _removed} ->
            Filesystem.sync_directory(Path.dirname(path), opts)

          {:error, reason, _failed_path} ->
            {:error, reason}

          {:error, reason} ->
            {:error, reason}

          other ->
            {:error, {:unexpected_cleanup_result, other}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_cleanup_tombstone(root, path, opts) do
    case File.stat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, _stat} ->
        with :ok <- Filesystem.sync_directory(Path.join(root, "ready"), opts),
             :ok <- Filesystem.sync_directory(Path.join(root, "quarantine"), opts) do
          remove_cleanup_tombstone(path, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp spool_error(reason) do
    Error.new(:temporary, :spool_failed, "spool write failed", %{reason: inspect(reason)})
  end

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, Error.new(:temporary, point, "injected spool fault")}
    else
      :ok
    end
  end
end

defmodule Manifold.Storage.Spool do
  @moduledoc """
  Durable local filesystem spool.
  """

  alias Manifold.Core.{Error, ID}
  alias Manifold.Storage.Spool.{Bundle, Manifest}

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

  @spec write_bundle(binary(), write_attrs(), Keyword.t()) ::
          {:ok, Bundle.t()} | {:error, Error.t()}
  def write_bundle(raw, attrs, opts \\ []) when is_binary(raw) and is_map(attrs) do
    root = Keyword.get(opts, :root, spool_root())
    min_free_bytes = Keyword.get(opts, :min_free_bytes, configured_min_free_bytes())
    ingest_id = Keyword.get(opts, :ingest_id, Map.get(attrs, :ingest_id, ID.generate()))

    with :ok <- validate_ingest_id(ingest_id),
         :ok <- ensure_layout(root),
         :ok <- ensure_capacity(root, min_free_bytes, opts),
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
    manifest_path = Path.join(tmp_path, "manifest.json")

    with :ok <- File.mkdir_p(tmp_path),
         :ok <- write_synced(raw_path, raw),
         :ok <- write_synced(manifest_path, Jason.encode!(manifest)),
         :ok <- sync_dir(tmp_path),
         :ok <- sync_dir(Path.join(root, "tmp")),
         :ok <- maybe_fault(opts, :before_ready_rename),
         :ok <- File.rename(tmp_path, ready_path),
         :ok <- sync_dir(Path.join(root, "ready")),
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
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:temporary, :spool_failed, "spool write failed", %{reason: inspect(reason)})}
    end
  end

  defp write_synced(path, data) do
    with {:ok, io} <- File.open(path, [:write, :binary, :exclusive]) do
      try do
        IO.binwrite(io, data)
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

  defp ensure_layout(root) do
    Enum.reduce_while(@required_dirs, :ok, fn dir, :ok ->
      case File.mkdir_p(Path.join(root, dir)) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt,
           {:error,
            Error.new(:temporary, :spool_failed, "spool layout failed", %{reason: inspect(reason)})}}
      end
    end)
  end

  defp ensure_capacity(_root, 0, _opts), do: :ok

  defp ensure_capacity(root, min_free_bytes, opts) do
    free_bytes_fun = Keyword.get(opts, :free_bytes_fun, &free_bytes/1)

    case free_bytes_fun.(root) do
      {:ok, free_bytes} when free_bytes >= min_free_bytes ->
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

  defp validate_ingest_id(ingest_id) do
    if ID.safe_path_id?(ingest_id) do
      :ok
    else
      {:error, Error.new(:permanent, :spool_failed, "invalid internal ingest id")}
    end
  end

  defp maybe_fault(opts, point) do
    if Keyword.get(opts, :fail_at) == point do
      {:error, Error.new(:temporary, point, "injected spool fault")}
    else
      :ok
    end
  end
end

defmodule Manifold.StorageTest do
  use ExUnit.Case, async: false

  alias Manifold.Storage.RawStore
  alias Manifold.Storage.RawStore.Local
  alias Manifold.Storage.Spool
  alias Manifold.Storage.Spool.Manifest

  @tag :tmp_dir
  test "bundle creation writes manifest and raw message in ready", %{tmp_dir: tmp_dir} do
    raw = "Subject: hi\r\n\r\nBody\r\n"

    assert {:ok, bundle} =
             Spool.write_bundle(raw, attrs(), root: tmp_dir, ingest_id: "ingest-1")

    assert File.exists?(Path.join(bundle.path, "raw.eml"))
    assert File.exists?(Path.join(bundle.path, "manifest.json"))
    refute File.exists?(Path.join([tmp_dir, "tmp", "ingest-1.partial"]))
  end

  @tag :tmp_dir
  test "ready bundles and their files have private permissions", %{tmp_dir: tmp_dir} do
    assert {:ok, bundle} =
             Spool.write_bundle("raw", attrs(), root: tmp_dir, ingest_id: "private-bundle")

    assert file_mode(bundle.path) == 0o700
    assert file_mode(bundle.raw_path) == 0o600
    assert file_mode(bundle.manifest_path) == 0o600
  end

  @tag :tmp_dir
  test "spool propagates permission application failures", %{tmp_dir: tmp_dir} do
    assert {:error, %{reason: :spool_failed}} =
             Spool.write_bundle("raw", attrs(),
               root: tmp_dir,
               ingest_id: "permission-failure",
               chmod_fun: fn _path, _mode -> {:error, :eperm} end
             )

    refute File.exists?(Path.join([tmp_dir, "ready", "permission-failure"]))
  end

  @tag :tmp_dir
  test "manifest round trip preserves byte count and SHA-256", %{tmp_dir: tmp_dir} do
    raw = "Subject: hi\r\n\r\nBody\r\n"

    assert {:ok, bundle} = Spool.write_bundle(raw, attrs(), root: tmp_dir, ingest_id: "ingest-2")
    assert {:ok, manifest} = Spool.read_manifest(bundle.path)

    assert manifest.raw_size == byte_size(raw)
    assert manifest.raw_sha256 == Manifest.sha256(raw)
    assert manifest.original_recipients == ["inbox@example.test"]
  end

  @tag :tmp_dir
  test "ready cleanup uses a resumable tombstone", %{tmp_dir: tmp_dir} do
    assert {:ok, bundle} =
             Spool.write_bundle("raw", attrs(), root: tmp_dir, ingest_id: "cleanup-1")

    assert {:error, %{reason: :after_cleanup_rename}} =
             Spool.cleanup_ready_bundle(bundle.path, fail_at: :after_cleanup_rename)

    refute File.exists?(bundle.path)
    assert File.dir?(Path.join([tmp_dir, "quarantine", "cleanup-cleanup-1"]))

    assert :ok = Spool.cleanup_ready_bundle(bundle.path)
    refute File.exists?(Path.join([tmp_dir, "quarantine", "cleanup-cleanup-1"]))
  end

  @tag :tmp_dir
  test "stream bundle creation writes enumerable chunks without buffering the source", %{
    tmp_dir: tmp_dir
  } do
    chunks = ["Subject: streamed\r\n", "\r\n", "Body", "\r\n"]
    raw = IO.iodata_to_binary(chunks)

    assert {:ok, bundle} =
             Spool.write_bundle_from_stream(chunks, attrs(),
               root: tmp_dir,
               ingest_id: "stream-enumerable",
               max_bytes: byte_size(raw)
             )

    assert File.read!(bundle.raw_path) == raw
    refute File.exists?(Path.join([tmp_dir, "tmp", "stream-enumerable.partial"]))
  end

  @tag :tmp_dir
  test "stream bundle creation accepts an IO binary stream", %{tmp_dir: tmp_dir} do
    raw = "Subject: io\r\n\r\nstreamed body\r\n"
    {:ok, io} = StringIO.open(raw)

    try do
      assert {:ok, bundle} =
               io
               |> IO.binstream(5)
               |> Spool.write_bundle_from_stream(attrs(),
                 root: tmp_dir,
                 ingest_id: "stream-io",
                 max_bytes: byte_size(raw)
               )

      assert File.read!(bundle.raw_path) == raw
    after
      StringIO.close(io)
    end
  end

  @tag :tmp_dir
  test "stream manifest records the exact byte count and SHA-256", %{tmp_dir: tmp_dir} do
    chunks = ["one", <<0, 1, 2>>, "three"]
    raw = IO.iodata_to_binary(chunks)

    assert {:ok, bundle} =
             Spool.write_bundle_from_stream(chunks, attrs(),
               root: tmp_dir,
               ingest_id: "stream-manifest",
               max_bytes: 1024
             )

    assert {:ok, manifest} = Spool.read_manifest(bundle.path)
    assert manifest.raw_size == byte_size(raw)
    assert manifest.raw_sha256 == Manifest.sha256(raw)
    assert bundle.manifest == manifest
  end

  @tag :tmp_dir
  test "stream bundle rejects data beyond the configured maximum and removes the partial", %{
    tmp_dir: tmp_dir
  } do
    assert {:error, %{class: :permanent, reason: :message_too_large}} =
             Spool.write_bundle_from_stream(["1234", "5"], attrs(),
               root: tmp_dir,
               ingest_id: "stream-too-large",
               max_bytes: 4
             )

    refute File.exists?(Path.join([tmp_dir, "tmp", "stream-too-large.partial"]))
    refute File.exists?(Path.join([tmp_dir, "ready", "stream-too-large"]))
  end

  @tag :tmp_dir
  test "stream bundle removes its partial when the source returns an error", %{tmp_dir: tmp_dir} do
    stream = Stream.map([{:ok, "partial"}, {:error, :upstream_closed}], & &1)

    assert {:error, %{class: :temporary, reason: :spool_failed, details: details}} =
             Spool.write_bundle_from_stream(stream, attrs(),
               root: tmp_dir,
               ingest_id: "stream-failed",
               max_bytes: 1024
             )

    assert details.reason =~ "upstream_closed"
    refute File.exists?(Path.join([tmp_dir, "tmp", "stream-failed.partial"]))
    refute File.exists?(Path.join([tmp_dir, "ready", "stream-failed"]))
  end

  @tag :tmp_dir
  test "stream bundle removes its partial when the enumerable raises", %{tmp_dir: tmp_dir} do
    stream =
      Stream.concat([
        ["partial"],
        Stream.map([:fail], fn :fail -> raise "source failed" end)
      ])

    assert {:error, %{class: :temporary, reason: :spool_failed}} =
             Spool.write_bundle_from_stream(stream, attrs(),
               root: tmp_dir,
               ingest_id: "stream-raised",
               max_bytes: 1024
             )

    refute File.exists?(Path.join([tmp_dir, "tmp", "stream-raised.partial"]))
    refute File.exists?(Path.join([tmp_dir, "ready", "stream-raised"]))
  end

  @tag :tmp_dir
  test "stream bundle syncs both files and atomically renames before ready directory sync", %{
    tmp_dir: tmp_dir
  } do
    test_pid = self()
    ingest_id = "stream-synced"
    ready_path = Path.join([tmp_dir, "ready", ingest_id])

    file_sync_fun = fn _io ->
      send(test_pid, :file_synced)
      :ok
    end

    dir_sync_fun = fn path ->
      send(test_pid, {:directory_synced, path, File.exists?(ready_path)})
      :ok
    end

    assert {:ok, bundle} =
             Spool.write_bundle_from_stream(["raw"], attrs(),
               root: tmp_dir,
               ingest_id: ingest_id,
               max_bytes: 3,
               file_sync_fun: file_sync_fun,
               dir_sync_fun: dir_sync_fun
             )

    assert_receive :file_synced
    assert_receive :file_synced
    assert_receive {:directory_synced, partial_path, false}
    assert partial_path == Path.join([tmp_dir, "tmp", ingest_id <> ".partial"])
    assert_receive {:directory_synced, tmp_path, false}
    assert tmp_path == Path.join(tmp_dir, "tmp")
    assert_receive {:directory_synced, ready_dir, true}
    assert ready_dir == Path.join(tmp_dir, "ready")
    assert bundle.path == ready_path
  end

  @tag :tmp_dir
  test "atomic ready transition leaves no ready bundle before rename", %{tmp_dir: tmp_dir} do
    assert {:error, %{reason: :before_ready_rename}} =
             Spool.write_bundle("raw", attrs(),
               root: tmp_dir,
               ingest_id: "ingest-3",
               fail_at: :before_ready_rename
             )

    refute File.exists?(Path.join([tmp_dir, "ready", "ingest-3"]))
    assert File.exists?(Path.join([tmp_dir, "tmp", "ingest-3.partial"]))
  end

  @tag :tmp_dir
  test "spool rejects failed writes and file syncs", %{tmp_dir: tmp_dir} do
    assert {:error, %{reason: :spool_failed}} =
             Spool.write_bundle("raw", attrs(),
               root: tmp_dir,
               ingest_id: "failed-write",
               write_fun: fn _io, _data -> {:error, :enospc} end
             )

    refute File.exists?(Path.join([tmp_dir, "ready", "failed-write"]))

    assert {:error, %{reason: :spool_failed}} =
             Spool.write_bundle("raw", attrs(),
               root: tmp_dir,
               ingest_id: "failed-file-sync",
               file_sync_fun: fn _io -> {:error, :eio} end
             )

    refute File.exists?(Path.join([tmp_dir, "ready", "failed-file-sync"]))
  end

  @tag :tmp_dir
  test "spool ignores unsupported directory sync and propagates real errors", %{tmp_dir: tmp_dir} do
    assert {:ok, _bundle} =
             Spool.write_bundle("raw", attrs(),
               root: tmp_dir,
               ingest_id: "unsupported-dir-sync",
               dir_sync_fun: fn _path -> {:error, :enotsup} end
             )

    assert {:error, %{reason: :spool_failed}} =
             Spool.write_bundle("raw", attrs(),
               root: tmp_dir,
               ingest_id: "failed-dir-sync",
               dir_sync_fun: fn _path -> {:error, :eio} end
             )

    refute File.exists?(Path.join([tmp_dir, "ready", "failed-dir-sync"]))
  end

  @tag :tmp_dir
  test "capacity keeps the configured reserve after writing the incoming message", %{
    tmp_dir: tmp_dir
  } do
    raw = "12345"

    assert {:error, %{class: :capacity, reason: :insufficient_spool_capacity}} =
             Spool.write_bundle(raw, attrs(),
               root: tmp_dir,
               ingest_id: "capacity-reserve",
               min_free_bytes: 100,
               free_bytes_fun: fn _path -> {:ok, 104} end
             )

    refute File.exists?(Path.join([tmp_dir, "tmp", "capacity-reserve.partial"]))
  end

  @tag :tmp_dir
  test "capacity checks incoming size when the configured reserve is zero", %{tmp_dir: tmp_dir} do
    assert {:error, %{class: :capacity, reason: :insufficient_spool_capacity}} =
             Spool.write_bundle("12345", attrs(),
               root: tmp_dir,
               ingest_id: "zero-capacity-reserve",
               min_free_bytes: 0,
               free_bytes_fun: fn _path -> {:ok, 4} end
             )

    refute File.exists?(Path.join([tmp_dir, "tmp", "zero-capacity-reserve.partial"]))
  end

  @tag :tmp_dir
  test "sender-controlled path components are rejected", %{tmp_dir: tmp_dir} do
    assert {:error, %{reason: :spool_failed}} =
             Spool.write_bundle("raw", attrs(), root: tmp_dir, ingest_id: "../evil")
  end

  @tag :tmp_dir
  test "partial-bundle cleanup removes old partials", %{tmp_dir: tmp_dir} do
    assert {:error, _} =
             Spool.write_bundle("raw", attrs(),
               root: tmp_dir,
               ingest_id: "ingest-4",
               fail_at: :before_ready_rename
             )

    assert :ok = Spool.cleanup_partials(tmp_dir, 0)
    refute File.exists?(Path.join([tmp_dir, "tmp", "ingest-4.partial"]))
  end

  @tag :tmp_dir
  test "ready orphan classification honors retention", %{tmp_dir: tmp_dir} do
    assert {:ok, bundle} =
             Spool.write_bundle("raw", attrs(), root: tmp_dir, ingest_id: "ingest-5")

    assert :orphan_retained = Spool.classify_ready_orphan(bundle.path, 3600)
    assert :orphan_expired = Spool.classify_ready_orphan(bundle.path, 0)
  end

  @tag :tmp_dir
  test "local raw store writes trusted object keys", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "raw.eml")
    File.write!(source, "raw")

    previous = Application.fetch_env!(:manifold_storage, :raw_store_dir)
    Application.put_env(:manifold_storage, :raw_store_dir, tmp_dir)

    try do
      key = RawStore.build_key("domain-id", DateTime.utc_now(), "delivery-id")
      assert {:ok, %{size: 3, sha256: sha256}} = RawStore.put_from_path(key, source)
      assert sha256 == Manifest.sha256("raw")
      assert {:error, :invalid_key} = RawStore.put_from_path("../bad", source)
    after
      Application.put_env(:manifold_storage, :raw_store_dir, previous)
    end
  end

  @tag :tmp_dir
  test "local raw store atomically replaces a corrupt final object", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.eml")
    root = Path.join(tmp_dir, "store")
    key = "raw/domain/2026/07/delivery.eml"
    destination = Path.join(root, key)

    File.mkdir_p!(Path.dirname(destination))
    File.write!(source, "complete raw message")
    File.write!(destination, "truncated")

    assert {:ok, %{size: 20, sha256: sha256}} =
             Local.put_from_path(%{root: root}, key, source, [])

    assert File.read!(destination) == "complete raw message"
    assert sha256 == Manifest.sha256("complete raw message")
    assert file_mode(destination) == 0o600
    assert file_mode(Path.dirname(destination)) == 0o700
  end

  @tag :tmp_dir
  test "local raw store leaves the previous object intact when replacement fails", %{
    tmp_dir: tmp_dir
  } do
    source = Path.join(tmp_dir, "source.eml")
    root = Path.join(tmp_dir, "store")
    key = "raw/domain/2026/07/delivery.eml"
    destination = Path.join(root, key)

    File.mkdir_p!(Path.dirname(destination))
    File.write!(source, "replacement")
    File.write!(destination, "previous")

    assert {:error, :after_copy} =
             Local.put_from_path(%{root: root}, key, source, fail_at: :after_copy)

    assert File.read!(destination) == "previous"
    assert [] = Path.wildcard(destination <> ".partial-*")
  end

  @tag :tmp_dir
  test "local raw store cleans up a truncated temporary copy", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.eml")
    root = Path.join(tmp_dir, "store")
    key = "raw/domain/2026/07/delivery.eml"
    destination = Path.join(root, key)

    File.mkdir_p!(Path.dirname(destination))
    File.write!(source, "replacement")
    File.write!(destination, "previous")

    copy_fun = fn _source, temporary ->
      File.write!(temporary, "truncated")
      {:error, :eio}
    end

    assert {:error, :eio} =
             Local.put_from_path(%{root: root}, key, source, copy_fun: copy_fun)

    assert File.read!(destination) == "previous"
    assert [] = Path.wildcard(destination <> ".partial-*")
  end

  @tag :tmp_dir
  test "local raw store checks file and directory sync results", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.eml")
    root = Path.join(tmp_dir, "store")
    key = "raw/domain/2026/07/delivery.eml"
    File.write!(source, "raw")

    assert {:error, :eio} =
             Local.put_from_path(%{root: root}, key, source,
               file_sync_fun: fn _io -> {:error, :eio} end
             )

    refute File.exists?(Path.join(root, key))

    assert {:ok, _stat} =
             Local.put_from_path(%{root: root}, key, source,
               dir_sync_fun: fn _path -> {:error, :einval} end
             )

    File.rm!(Path.join(root, key))

    assert {:error, :eacces} =
             Local.put_from_path(%{root: root}, key, source,
               dir_sync_fun: fn _path -> {:error, :eacces} end
             )
  end

  @tag :tmp_dir
  test "local raw store propagates permission application failures", %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "source.eml")
    File.write!(source, "raw")

    assert {:error, :eperm} =
             Local.put_from_path(
               %{root: Path.join(tmp_dir, "store")},
               "raw/domain/2026/07/delivery.eml",
               source,
               chmod_fun: fn _path, _mode -> {:error, :eperm} end
             )
  end

  defp attrs do
    %{
      received_at: DateTime.utc_now(),
      peer_ip: "127.0.0.1",
      helo: "sender.example",
      envelope_from: "sender@example.net",
      original_recipients: ["inbox@example.test"],
      routes: [
        %{
          original_recipient: "inbox@example.test",
          canonical_recipient: "inbox@example.test",
          plus_tag: nil,
          domain_id: "domain-id",
          mailbox_ids: ["mailbox-id"]
        }
      ]
    }
  end

  defp file_mode(path) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o777)
  end
end

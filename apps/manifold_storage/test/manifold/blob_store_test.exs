defmodule Manifold.Storage.BlobStoreTest do
  use ExUnit.Case, async: true

  alias Manifold.Storage.BlobStore
  alias Manifold.Storage.BlobStore.Local
  alias Manifold.Storage.Spool.Manifest

  @content "attachment bytes"
  @sha256 Manifest.sha256(@content)

  test "builds a trusted content-addressed key" do
    assert {:ok, "blobs/sha256/" <> prefix_and_digest} = BlobStore.build_key(@sha256)
    assert prefix_and_digest == String.slice(@sha256, 0, 2) <> "/" <> @sha256

    assert {:error, :invalid_sha256} = BlobStore.build_key(String.upcase(@sha256))
    assert {:error, :invalid_sha256} = BlobStore.build_key("../" <> @sha256)
    assert {:error, :invalid_sha256} = BlobStore.build_key("not-a-digest")
    assert {:error, :invalid_sha256} = BlobStore.build_key(nil)
  end

  @tag :tmp_dir
  test "atomically puts, opens, stats, and deletes a private blob", %{tmp_dir: tmp_dir} do
    source = write_source(tmp_dir, @content)
    content_size = byte_size(@content)
    {:ok, key} = BlobStore.build_key(@sha256)

    assert {:ok, %{size: ^content_size, sha256: @sha256}} =
             Local.put_from_path(config(tmp_dir), key, source, expected_size: content_size)

    destination = Path.join(store_root(tmp_dir), key)
    assert file_mode(destination) == 0o600
    assert file_mode(Path.dirname(destination)) == 0o700
    assert [] = Path.wildcard(destination <> ".partial-*")

    assert {:ok, io} = Local.open(config(tmp_dir), key, [])
    assert IO.binread(io, :eof) == @content
    assert :ok = File.close(io)

    assert {:ok, %{size: ^content_size, sha256: @sha256}} =
             Local.stat(config(tmp_dir), key, [])

    assert :ok = Local.delete(config(tmp_dir), key, [])
    refute File.exists?(destination)
  end

  @tag :tmp_dir
  test "repeated put of the same content is idempotent", %{tmp_dir: tmp_dir} do
    source = write_source(tmp_dir, @content)
    {:ok, key} = BlobStore.build_key(@sha256)
    opts = [expected_size: byte_size(@content)]

    assert {:ok, first_stat} = Local.put_from_path(config(tmp_dir), key, source, opts)
    assert {:ok, ^first_stat} = Local.put_from_path(config(tmp_dir), key, source, opts)
    assert File.read!(Path.join(store_root(tmp_dir), key)) == @content
    assert [] = Path.wildcard(Path.join(store_root(tmp_dir), key) <> ".partial-*")
  end

  @tag :tmp_dir
  test "syncs newly created hierarchy entries and the final rename", %{tmp_dir: tmp_dir} do
    source = write_source(tmp_dir, @content)
    {:ok, key} = BlobStore.build_key(@sha256)
    root = store_root(tmp_dir)
    destination = Path.join(root, key)
    leaf = Path.dirname(destination)
    test_pid = self()

    dir_sync_fun = fn path ->
      send(test_pid, {:directory_synced, path, File.exists?(destination)})
      :ok
    end

    assert {:ok, %{sha256: @sha256}} =
             Local.put_from_path(config(tmp_dir), key, source,
               expected_size: byte_size(@content),
               dir_sync_fun: dir_sync_fun
             )

    assert_receive {:directory_synced, root_parent, false}
    assert root_parent == Path.dirname(root)
    assert_receive {:directory_synced, ^root, false}
    assert_receive {:directory_synced, blobs, false}
    assert blobs == Path.join(root, "blobs")
    assert_receive {:directory_synced, sha256, false}
    assert sha256 == Path.join(root, "blobs/sha256")
    assert_receive {:directory_synced, ^leaf, true}
    refute_receive {:directory_synced, _path, _destination_exists}
  end

  @tag :tmp_dir
  test "a final directory sync failure remains tagged and retryable", %{tmp_dir: tmp_dir} do
    source = write_source(tmp_dir, @content)
    {:ok, key} = BlobStore.build_key(@sha256)
    destination = Path.join(store_root(tmp_dir), key)
    leaf = Path.dirname(destination)

    dir_sync_fun = fn path ->
      if path == leaf and File.exists?(destination), do: {:error, :eio}, else: :ok
    end

    assert {:error, :eio} =
             Local.put_from_path(config(tmp_dir), key, source,
               expected_size: byte_size(@content),
               dir_sync_fun: dir_sync_fun
             )

    assert File.read!(destination) == @content
    assert [] = partials(tmp_dir)

    assert {:ok, %{sha256: @sha256}} =
             Local.put_from_path(config(tmp_dir), key, source, expected_size: byte_size(@content))
  end

  @tag :tmp_dir
  test "verifies the source SHA-256 before exposing the final key", %{tmp_dir: tmp_dir} do
    source = write_source(tmp_dir, "different bytes")
    {:ok, key} = BlobStore.build_key(@sha256)

    assert {:error, {:sha256_mismatch, %{expected: @sha256, actual: actual}}} =
             Local.put_from_path(config(tmp_dir), key, source,
               expected_size: byte_size("different bytes")
             )

    assert actual == Manifest.sha256("different bytes")
    refute File.exists?(Path.join(store_root(tmp_dir), key))
    assert [] = partials(tmp_dir)
  end

  @tag :tmp_dir
  test "verifies the expected size before exposing the final key", %{tmp_dir: tmp_dir} do
    source = write_source(tmp_dir, @content)
    {:ok, key} = BlobStore.build_key(@sha256)

    assert {:error, {:size_mismatch, %{expected: wrong_size, actual: actual_size}}} =
             Local.put_from_path(config(tmp_dir), key, source,
               expected_size: byte_size(@content) + 1
             )

    assert wrong_size == byte_size(@content) + 1
    assert actual_size == byte_size(@content)
    refute File.exists?(Path.join(store_root(tmp_dir), key))
    assert [] = partials(tmp_dir)
  end

  @tag :tmp_dir
  test "rejects non-canonical and untrusted keys for every operation", %{tmp_dir: tmp_dir} do
    source = write_source(tmp_dir, @content)

    invalid_keys = [
      "../blobs/sha256/#{String.slice(@sha256, 0, 2)}/#{@sha256}",
      "/blobs/sha256/#{String.slice(@sha256, 0, 2)}/#{@sha256}",
      "blobs/sha256/ff/#{@sha256}",
      "blobs/sha256/#{String.slice(@sha256, 0, 2)}/#{String.upcase(@sha256)}",
      "raw/#{@sha256}"
    ]

    for key <- invalid_keys do
      assert {:error, :invalid_key} =
               Local.put_from_path(config(tmp_dir), key, source,
                 expected_size: byte_size(@content)
               )

      assert {:error, :invalid_key} = Local.open(config(tmp_dir), key, [])
      assert {:error, :invalid_key} = Local.stat(config(tmp_dir), key, [])
      assert {:error, :invalid_key} = Local.delete(config(tmp_dir), key, [])
    end

    assert [] = partials(tmp_dir)
  end

  @tag :tmp_dir
  test "a failure before rename cleans the partial and leaves no final object", %{
    tmp_dir: tmp_dir
  } do
    source = write_source(tmp_dir, @content)
    {:ok, key} = BlobStore.build_key(@sha256)

    assert {:error, :before_rename} =
             Local.put_from_path(config(tmp_dir), key, source,
               expected_size: byte_size(@content),
               fail_at: :before_rename
             )

    refute File.exists?(Path.join(store_root(tmp_dir), key))
    assert [] = partials(tmp_dir)
  end

  @tag :tmp_dir
  test "a failed partial copy is cleaned without replacing an existing blob", %{tmp_dir: tmp_dir} do
    source = write_source(tmp_dir, @content)
    {:ok, key} = BlobStore.build_key(@sha256)
    destination = Path.join(store_root(tmp_dir), key)

    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, "existing")

    copy_fun = fn _source, temporary ->
      File.write!(temporary, "truncated")
      {:error, :eio}
    end

    assert {:error, :eio} =
             Local.put_from_path(config(tmp_dir), key, source,
               expected_size: byte_size(@content),
               copy_fun: copy_fun
             )

    assert File.read!(destination) == "existing"
    assert [] = partials(tmp_dir)
  end

  defp config(tmp_dir), do: %{root: store_root(tmp_dir)}
  defp store_root(tmp_dir), do: Path.join(tmp_dir, "blob-store")

  defp write_source(tmp_dir, content) do
    path = Path.join(tmp_dir, "source.bin")
    File.write!(path, content)
    path
  end

  defp partials(tmp_dir) do
    Path.wildcard(Path.join([store_root(tmp_dir), "**", "*.partial-*"]), match_dot: true)
  end

  defp file_mode(path) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o777)
  end
end

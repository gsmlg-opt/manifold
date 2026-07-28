defmodule Manifold.StorageTest do
  use ExUnit.Case, async: false

  alias Manifold.Storage.RawStore
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
  test "manifest round trip preserves byte count and SHA-256", %{tmp_dir: tmp_dir} do
    raw = "Subject: hi\r\n\r\nBody\r\n"

    assert {:ok, bundle} = Spool.write_bundle(raw, attrs(), root: tmp_dir, ingest_id: "ingest-2")
    assert {:ok, manifest} = Spool.read_manifest(bundle.path)

    assert manifest.raw_size == byte_size(raw)
    assert manifest.raw_sha256 == Manifest.sha256(raw)
    assert manifest.original_recipients == ["inbox@example.test"]
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
end

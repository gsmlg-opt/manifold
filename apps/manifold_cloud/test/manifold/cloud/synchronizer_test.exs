defmodule Manifold.Cloud.SynchronizerTest do
  use ExUnit.Case, async: true

  alias Manifold.Cloud.Synchronizer
  alias Manifold.Core.Error

  @moduletag :tmp_dir
  @raw "raw\n"
  @sha256 :crypto.hash(:sha256, @raw) |> Base.encode16(case: :lower)

  defmodule FakeClient do
    def stream_raw(_source, _edge_delivery_id, opts) do
      {:ok, [Keyword.fetch!(opts, :raw)]}
    end

    def acknowledge(_source, edge_delivery_id, local_delivery_id, raw_sha256, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:acknowledged, edge_delivery_id, local_delivery_id, raw_sha256}
      )

      :ok
    end
  end

  defmodule FakeIngest do
    def lookup_ingress(_source_id, _edge_delivery_id) do
      {:error, Error.new(:permanent, :not_found, "not imported")}
    end

    def accept_edge(source_id, edge_delivery_id, bundle, routes) do
      test_pid = Process.get(:synchronizer_test_pid)
      send(test_pid, {:accepted, source_id, edge_delivery_id, bundle, routes})

      {:ok,
       %{
         inbound_delivery_id: "local-1",
         raw_sha256: bundle.manifest.raw_sha256
       }}
    end
  end

  defmodule FailingIngest do
    def lookup_ingress(_source_id, _edge_delivery_id) do
      {:error, Error.new(:permanent, :not_found, "not imported")}
    end

    def accept_edge(_source_id, _edge_delivery_id, _bundle, _routes) do
      {:error, Error.new(:temporary, :database_unavailable, "database unavailable")}
    end
  end

  defmodule NoStreamClient do
    def stream_raw(_source, _edge_delivery_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), :unexpected_raw_fetch)
      {:error, Error.new(:temporary, :unexpected_raw_fetch, "raw fetch was not expected")}
    end

    def acknowledge(_source, edge_delivery_id, local_delivery_id, raw_sha256, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:acknowledged, edge_delivery_id, local_delivery_id, raw_sha256}
      )

      :ok
    end
  end

  setup do
    Process.put(:synchronizer_test_pid, self())
    on_exit(fn -> Process.delete(:synchronizer_test_pid) end)
  end

  test "accepts verified raw mail before acknowledging the edge", %{tmp_dir: tmp_dir} do
    source = [source_id: "source-1"]

    assert :ok =
             Synchronizer.sync_delivery(source, delivery_metadata(),
               client: FakeClient,
               ingest: FakeIngest,
               client_opts: [raw: @raw, test_pid: self()],
               spool_opts: [root: tmp_dir]
             )

    assert_receive {:accepted, "source-1", "edge-1", bundle, [route]}
    assert bundle.manifest.raw_size == byte_size(@raw)
    assert bundle.manifest.raw_sha256 == @sha256
    assert route["mailbox_ids"] == ["mailbox-1"]
    assert_receive {:acknowledged, "edge-1", "local-1", @sha256}
  end

  test "does not accept or acknowledge raw content with a conflicting digest", %{tmp_dir: tmp_dir} do
    source = [source_id: "source-1"]

    assert {:error, %{class: :permanent, reason: :edge_raw_mismatch}} =
             Synchronizer.sync_delivery(source, delivery_metadata(),
               client: FakeClient,
               ingest: FakeIngest,
               client_opts: [raw: "nope", test_pid: self()],
               spool_opts: [root: tmp_dir]
             )

    refute_received {:accepted, _, _, _, _}
    refute_received {:acknowledged, _, _, _}
    assert [] == Path.wildcard(Path.join([tmp_dir, "ready", "*"]))
  end

  test "reuses a ready bundle after acceptance fails without downloading raw content again", %{
    tmp_dir: tmp_dir
  } do
    source = [source_id: "source-1"]

    assert {:error, %{class: :temporary, reason: :database_unavailable}} =
             Synchronizer.sync_delivery(source, delivery_metadata(),
               client: FakeClient,
               ingest: FailingIngest,
               client_opts: [raw: @raw, test_pid: self()],
               spool_opts: [root: tmp_dir]
             )

    assert [_ready_bundle] = Path.wildcard(Path.join([tmp_dir, "ready", "*"]))

    assert :ok =
             Synchronizer.sync_delivery(source, delivery_metadata(),
               client: NoStreamClient,
               ingest: FakeIngest,
               client_opts: [test_pid: self()],
               spool_opts: [root: tmp_dir]
             )

    refute_received :unexpected_raw_fetch
    assert_receive {:accepted, "source-1", "edge-1", _bundle, _routes}
    assert_receive {:acknowledged, "edge-1", "local-1", @sha256}
  end

  defp delivery_metadata do
    %{
      "edge_delivery_id" => "edge-1",
      "peer_ip" => "192.0.2.10",
      "helo" => "sender.example",
      "envelope_from" => "sender@example.net",
      "received_at" => "2026-07-29T12:00:00Z",
      "original_recipients" => ["inbox@example.test"],
      "routes" => [
        %{
          "original_recipient" => "inbox@example.test",
          "canonical_recipient" => "inbox@example.test",
          "plus_tag" => nil,
          "domain_id" => "domain-1",
          "mailbox_ids" => ["mailbox-1"]
        }
      ],
      "raw_size" => byte_size(@raw),
      "raw_sha256" => @sha256
    }
  end
end

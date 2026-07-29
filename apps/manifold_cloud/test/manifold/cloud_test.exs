defmodule Manifold.CloudTest do
  use ExUnit.Case, async: true

  alias Manifold.Accounts.RecipientSnapshot
  alias Manifold.Cloud
  alias Manifold.Core.Error

  defmodule SnapshotAccounts do
    def recipient_snapshot do
      {:ok,
       %RecipientSnapshot{
         schema_version: 1,
         revision: 4,
         generated_at: ~U[2026-07-29 12:00:00Z],
         expires_at: ~U[2026-07-30 12:00:00Z],
         digest: String.duplicate("a", 64),
         domains: [],
         routes: []
       }}
    end
  end

  defmodule RecordingClient do
    def publish_snapshot(source, snapshot, _opts) do
      send(source[:test_pid], {:published, snapshot.revision})
      :ok
    end

    def list_deliveries(source, _opts) do
      send(source[:test_pid], :listed)
      {:ok, []}
    end
  end

  defmodule PoisonPageClient do
    def list_deliveries(source, _opts) do
      send(source[:test_pid], :listed)

      {:ok,
       [
         %{
           "edge_delivery_id" => "poison-1",
           "raw_sha256" => String.duplicate("a", 64)
         },
         %{
           "edge_delivery_id" => "healthy-1",
           "raw_sha256" => String.duplicate("b", 64)
         }
       ]}
    end

    def report_failure(source, edge_delivery_id, raw_sha256, reason, _opts) do
      send(source[:test_pid], {:failed_at_edge, edge_delivery_id, raw_sha256, reason})
      :ok
    end
  end

  defmodule PoisonAwareSynchronizer do
    def sync_delivery(_source, %{"edge_delivery_id" => "poison-1"}, _opts) do
      {:error, Error.new(:permanent, :edge_raw_mismatch, "raw mismatch")}
    end

    def sync_delivery(source, %{"edge_delivery_id" => "healthy-1"}, _opts) do
      send(source[:test_pid], :healthy_synchronized)
      :ok
    end
  end

  test "publishes the current account route snapshot" do
    source = [test_pid: self()]

    assert :ok =
             Cloud.publish_routes(
               source: source,
               accounts: SnapshotAccounts,
               client: RecordingClient
             )

    assert_receive {:published, 4}
  end

  test "pulls a bounded pending-delivery page" do
    source = [test_pid: self()]

    assert {:ok, 0} =
             Cloud.pull_once(
               source: source,
               client: RecordingClient,
               synchronizer: Manifold.Cloud.Synchronizer
             )

    assert_receive :listed
  end

  test "scheduled operations no-op when no edge source is configured" do
    assert :disabled = Cloud.publish_routes(source: nil)
    assert :disabled = Cloud.pull_once(source: nil)
  end

  test "isolates a permanently failed delivery and continues the page" do
    source = [test_pid: self()]

    assert {:ok, 1} =
             Cloud.pull_once(
               source: source,
               client: PoisonPageClient,
               synchronizer: PoisonAwareSynchronizer
             )

    assert_receive {:failed_at_edge, "poison-1", raw_sha256, :edge_raw_mismatch}
    assert raw_sha256 == String.duplicate("a", 64)
    assert_receive :healthy_synchronized
  end
end

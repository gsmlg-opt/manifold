defmodule Manifold.Edge.RouteResolverTest do
  use ExUnit.Case, async: true

  alias Manifold.Edge.{RouteResolver, RouteSnapshot}
  alias Manifold.Edge.RouteSnapshot.Route

  @now ~U[2026-07-29 12:00:00Z]

  test "resolves exact and plus-address routes from one frozen snapshot" do
    snapshot = snapshot()

    assert {:ok, exact} =
             RouteResolver.resolve(snapshot, "Team@Example.TEST", now: @now)

    assert exact.original_recipient == "Team@Example.TEST"
    assert exact.canonical_recipient == "team@example.test"
    assert exact.plus_tag == nil
    assert exact.domain_id == "domain-1"
    assert exact.mailbox_ids == ["mailbox-1", "mailbox-2"]
    assert exact.snapshot_revision == 7

    assert {:ok, plus} =
             RouteResolver.resolve(snapshot, "team+sales@example.test", now: @now)

    assert plus.canonical_recipient == "team@example.test"
    assert plus.plus_tag == "sales"
    assert plus.mailbox_ids == ["mailbox-1", "mailbox-2"]
  end

  test "does not apply plus addressing when the exact route disables it" do
    snapshot =
      snapshot([
        %Route{
          canonical_address: "billing@example.test",
          domain_id: "domain-1",
          mailbox_ids: ["mailbox-3"],
          plus_addressing_enabled: false
        }
      ])

    assert {:error, %{class: :permanent, reason: :unknown_recipient}} =
             RouteResolver.resolve(snapshot, "billing+tag@example.test", now: @now)
  end

  test "classifies absent and expired snapshots as temporary failures" do
    assert {:error, %{class: :temporary, reason: :route_snapshot_unavailable}} =
             RouteResolver.resolve(nil, "team@example.test", now: @now)

    expired = %{snapshot() | expires_at: DateTime.add(@now, -1, :second)}

    assert {:error, %{class: :temporary, reason: :route_snapshot_expired}} =
             RouteResolver.resolve(expired, "team@example.test", now: @now)
  end

  test "classifies invalid syntax separately from unknown recipients" do
    assert {:error, %{reason: :invalid_address}} =
             RouteResolver.resolve(snapshot(), "not-an-address", now: @now)

    assert {:error, %{class: :permanent, reason: :unknown_recipient}} =
             RouteResolver.resolve(snapshot(), "missing@example.test", now: @now)
  end

  defp snapshot(routes \\ nil) do
    %RouteSnapshot{
      schema_version: 1,
      revision: 7,
      digest: String.duplicate("a", 64),
      generated_at: DateTime.add(@now, -60, :second),
      expires_at: DateTime.add(@now, 3600, :second),
      routes:
        routes ||
          [
            %Route{
              canonical_address: "team@example.test",
              domain_id: "domain-1",
              mailbox_ids: ["mailbox-1", "mailbox-2"],
              plus_addressing_enabled: true
            }
          ]
    }
  end
end

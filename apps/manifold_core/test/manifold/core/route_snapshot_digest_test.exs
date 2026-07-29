defmodule Manifold.Core.RouteSnapshotDigestTest do
  use ExUnit.Case, async: true

  alias Manifold.Core.RouteSnapshotDigest

  test "computes the same digest for equivalent atom and string keyed snapshots" do
    domains = [%{id: "domain-1", name: "example.test", plus_addressing_enabled: true}]

    routes = [
      %{
        canonical_address: "team@example.test",
        domain_id: "domain-1",
        mailbox_ids: ["mailbox-1"],
        plus_addressing_enabled: true
      }
    ]

    assert {:ok, digest} = RouteSnapshotDigest.compute(1, domains, routes)

    assert :ok =
             RouteSnapshotDigest.verify(
               1,
               Jason.decode!(Jason.encode!(domains)),
               Jason.decode!(Jason.encode!(routes)),
               digest
             )

    assert {:error, :invalid_snapshot} =
             RouteSnapshotDigest.verify(
               1,
               domains,
               [%{hd(routes) | mailbox_ids: ["mailbox-2"]}],
               digest
             )
  end
end

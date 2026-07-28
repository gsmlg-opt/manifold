defmodule Manifold.CoreTest do
  use ExUnit.Case, async: true

  alias Manifold.Core.{Address, DeliveryState, Domain}

  test "normalizes ASCII domains" do
    assert {:ok, "example.test"} = Domain.normalize("Example.TEST.")
  end

  test "rejects non-ASCII envelope addresses" do
    assert {:error, %{reason: :invalid_address}} = Address.parse("jose@exämple.test")
  end

  test "preserves original local part and canonicalizes lookup local part" do
    assert {:ok, address} = Address.parse("Inbox+Tag@Example.TEST")
    assert address.local_part == "Inbox+Tag"
    assert address.canonical_local_part == "inbox+tag"
    assert address.domain == "example.test"
  end

  test "splits plus addressing" do
    assert {"inbox", "tag"} = Address.split_plus("inbox+tag")
    assert {"inbox", nil} = Address.split_plus("inbox")
  end

  test "validates delivery-state transitions" do
    assert :ok = DeliveryState.validate_raw_transition("spooled", "archived")

    assert {:error, %{reason: :invalid_state_transition}} =
             DeliveryState.validate_raw_transition("archived", "spooled")
  end
end

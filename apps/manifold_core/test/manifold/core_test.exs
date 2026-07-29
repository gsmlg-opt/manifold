defmodule Manifold.CoreTest do
  use ExUnit.Case, async: true

  alias Manifold.Core.{Address, DeliveryState, Domain}

  test "normalizes ASCII domains" do
    assert {:ok, "example.test"} = Domain.normalize("Example.TEST.")
  end

  test "rejects non-ASCII envelope addresses" do
    assert {:error, %{reason: :invalid_address}} = Address.parse("jose@exämple.test")
  end

  test "rejects invalid UTF-8 bytes without raising" do
    assert {:error, %{reason: :invalid_address}} = Address.parse(<<"inbox@", 0xFF, ".test">>)
    assert {:error, %{reason: :invalid_domain}} = Domain.normalize(<<0xFF, ".test">>)
  end

  test "preserves original local part and canonicalizes lookup local part" do
    assert {:ok, address} = Address.parse("Inbox+Tag@Example.TEST")
    assert address.local_part == "Inbox+Tag"
    assert address.canonical_local_part == "inbox+tag"
    assert address.domain == "example.test"
  end

  test "rejects dot-atoms with leading, trailing, or consecutive dots" do
    for local_part <- [".inbox", "inbox.", "in..box"] do
      assert {:error, %{class: :permanent, reason: :invalid_address}} =
               Address.parse(local_part <> "@example.test")
    end
  end

  test "rejects malformed angle wrappers" do
    assert {:ok, address} = Address.parse("<Inbox@Example.TEST>")
    assert address.local_part == "Inbox"
    assert address.domain == "example.test"

    assert {:error, %{class: :permanent, reason: :invalid_address}} =
             Address.parse("<a@example.test>>")
  end

  test "enforces the SMTP local-part byte limit" do
    local_part = String.duplicate("a", 64)

    assert {:ok, address} = Address.parse(local_part <> "@example.test")
    assert address.local_part == local_part

    assert {:error, %{class: :permanent, reason: :invalid_address}} =
             Address.parse(local_part <> "a@example.test")
  end

  test "enforces the SMTP address byte limit" do
    domain_at_address_limit =
      Enum.join(
        [
          String.duplicate("a", 63),
          String.duplicate("b", 63),
          String.duplicate("c", 63),
          String.duplicate("d", 60)
        ],
        "."
      )

    assert byte_size("a@" <> domain_at_address_limit) == 254
    assert {:ok, _address} = Address.parse("a@" <> domain_at_address_limit)

    assert {:error, %{class: :permanent, reason: :invalid_address}} =
             Address.parse("aa@" <> domain_at_address_limit)
  end

  test "enforces the SMTP domain byte limit" do
    domain_at_limit =
      Enum.join(
        [
          String.duplicate("a", 63),
          String.duplicate("b", 63),
          String.duplicate("c", 63),
          String.duplicate("d", 63)
        ],
        "."
      )

    domain_over_limit =
      Enum.join(
        [
          String.duplicate("a", 63),
          String.duplicate("b", 63),
          String.duplicate("c", 63),
          String.duplicate("d", 62),
          "e"
        ],
        "."
      )

    assert byte_size(domain_at_limit) == 255
    assert byte_size(domain_over_limit) == 256
    assert {:ok, ^domain_at_limit} = Domain.normalize(domain_at_limit)

    assert {:error, %{class: :permanent, reason: :invalid_domain}} =
             Domain.normalize(domain_over_limit)
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

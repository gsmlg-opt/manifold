defmodule Manifold.AccountLifecycle.SchemaTest do
  use Manifold.DataCase, async: true

  alias Manifold.AccountLifecycle.Schema.AccountPurge

  test "purge requires an opaque mailbox id and valid lifecycle state" do
    changeset = AccountPurge.changeset(%AccountPurge{}, %{mailbox_id: Ecto.UUID.generate()})

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :status) == "requested"
    assert Ecto.Changeset.get_field(changeset, :stage) == "discover"
    refute Map.has_key?(changeset.changes, :address)
  end

  test "account purge queue is configured and visible" do
    assert "account_purge" in Manifold.Data.ObanJobs.queues()
  end
end

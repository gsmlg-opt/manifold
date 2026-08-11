defmodule Manifold.AccountLifecycle.Schema.PurgeDelivery do
  @moduledoc false

  use Manifold.AccountLifecycle.Schema

  alias Manifold.AccountLifecycle.Schema.AccountPurge

  schema "account_purge_deliveries" do
    belongs_to(:purge, AccountPurge)
    field(:inbound_delivery_id, :binary_id)
    field(:disposition, :string, default: "pending")

    timestamps(type: :utc_datetime_usec)
  end
end

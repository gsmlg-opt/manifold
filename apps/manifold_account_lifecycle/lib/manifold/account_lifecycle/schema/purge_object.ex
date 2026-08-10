defmodule Manifold.AccountLifecycle.Schema.PurgeObject do
  @moduledoc false

  use Manifold.AccountLifecycle.Schema

  alias Manifold.AccountLifecycle.Schema.AccountPurge

  schema "account_purge_objects" do
    belongs_to(:purge, AccountPurge)
    field(:kind, :string)
    field(:object_key, :string)
    field(:status, :string, default: "pending")
    field(:attempts, :integer, default: 0)
    field(:last_error, :string)

    timestamps(type: :utc_datetime_usec)
  end
end

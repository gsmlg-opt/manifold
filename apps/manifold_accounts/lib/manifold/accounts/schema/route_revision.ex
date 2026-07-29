defmodule Manifold.Accounts.Schema.RouteRevision do
  @moduledoc false

  use Manifold.Accounts.Schema

  schema "account_route_revisions" do
    field(:revision, :integer)

    timestamps(type: :utc_datetime_usec)
  end
end

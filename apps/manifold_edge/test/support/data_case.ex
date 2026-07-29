defmodule Manifold.Edge.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Manifold.Edge.Repo

      import Ecto.Query
    end
  end

  setup tags do
    owner =
      Ecto.Adapters.SQL.Sandbox.start_owner!(
        Manifold.Edge.Repo,
        shared: not tags[:async]
      )

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(owner) end)

    :ok
  end
end

defmodule Manifold.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias Manifold.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Manifold.DataCase
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Manifold.Repo, shared: not tags[:async])

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    :ok
  end
end

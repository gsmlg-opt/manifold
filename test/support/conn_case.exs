defmodule ManifoldWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ManifoldWeb.Endpoint

      use ManifoldWeb, :verified_routes

      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import ManifoldWeb.ConnCase
    end
  end

  setup tags do
    owner = Ecto.Adapters.SQL.Sandbox.start_owner!(Manifold.Repo, shared: not tags[:async])

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  def log_in_owner(conn, owner) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:owner_id, owner.id)
  end
end

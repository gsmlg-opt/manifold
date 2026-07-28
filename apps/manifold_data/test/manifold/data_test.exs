defmodule Manifold.DataTest do
  use Manifold.DataCase, async: true

  alias Manifold.Data.Health

  test "database health check succeeds inside test database" do
    assert Health.database_available?()
  end
end

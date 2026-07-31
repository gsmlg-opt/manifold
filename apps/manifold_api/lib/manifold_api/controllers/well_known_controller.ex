defmodule ManifoldAPI.WellKnownController do
  use ManifoldAPI, :controller

  alias ManifoldAPI.Discovery

  def show(conn, _params) do
    json(conn, Discovery.document())
  end
end

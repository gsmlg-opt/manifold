defmodule ManifoldAPI.HealthController do
  use ManifoldAPI, :controller

  alias ManifoldAPI.Mail

  def show(conn, _params) do
    json(conn, Mail.health())
  end
end

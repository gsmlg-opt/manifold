defmodule Manifold.Edge.Repo do
  use Ecto.Repo,
    otp_app: :manifold_edge,
    adapter: Ecto.Adapters.Postgres
end

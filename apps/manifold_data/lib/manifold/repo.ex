defmodule Manifold.Repo do
  use Ecto.Repo,
    otp_app: :manifold_data,
    adapter: Ecto.Adapters.Postgres
end

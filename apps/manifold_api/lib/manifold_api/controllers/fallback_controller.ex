defmodule ManifoldAPI.FallbackController do
  use ManifoldAPI, :controller

  alias Manifold.Core.Error
  alias ManifoldAPI.Error, as: APIError

  def call(conn, {:error, %Error{} = error}) do
    conn
    |> put_status(APIError.status(error))
    |> json(APIError.to_map(error))
  end
end

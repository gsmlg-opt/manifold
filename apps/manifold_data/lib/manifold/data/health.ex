defmodule Manifold.Data.Health do
  @moduledoc """
  Database health helpers.
  """

  alias Manifold.Repo

  @spec database_available?() :: boolean()
  def database_available? do
    case Repo.query("select 1", []) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end
end

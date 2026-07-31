defmodule ManifoldAPI do
  @moduledoc """
  Phoenix API interface for Manifold mail read and search.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def controller do
    quote do
      use Phoenix.Controller,
        formats: [:json],
        layouts: []

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: ManifoldAPI.Endpoint,
        router: ManifoldAPI.Router
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/router helper.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end

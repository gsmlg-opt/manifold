defmodule Manifold.Edge.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = repo_children() ++ reconciler_children() ++ api_children()

    opts = [strategy: :one_for_one, name: Manifold.Edge.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp repo_children do
    if Application.get_env(:manifold_edge, Manifold.Edge.Repo) do
      [Manifold.Edge.Repo]
    else
      []
    end
  end

  defp api_children do
    if Application.get_env(:manifold_edge, :api_server, false) do
      [
        {Bandit,
         plug: Manifold.Edge.Router,
         scheme: :http,
         ip: parse_bind(Application.fetch_env!(:manifold_edge, :api_bind)),
         port: Application.fetch_env!(:manifold_edge, :api_port)}
      ]
    else
      []
    end
  end

  defp reconciler_children do
    if Application.get_env(:manifold_edge, :reconciler_enabled, false) do
      [{Manifold.Edge.Reconciler, []}]
    else
      []
    end
  end

  defp parse_bind(bind) do
    bind
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> address
      {:error, _reason} -> raise ArgumentError, "invalid MANIFOLD_EDGE_API_BIND=#{bind}"
    end
  end
end

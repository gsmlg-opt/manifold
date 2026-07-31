defmodule ManifoldAPI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: ManifoldAPI.PubSub},
      ManifoldAPI.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ManifoldAPI.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ManifoldAPI.Endpoint.config_change(changed, removed)
    :ok
  end
end

defmodule Manifold.Connectors.Application do
  @moduledoc false

  use Application

  alias Manifold.Connectors.ActivityLog.Handler

  @impl true
  def start(_type, _args) do
    Handler.attach()

    Supervisor.start_link([], strategy: :one_for_one, name: Manifold.Connectors.Supervisor)
  end
end

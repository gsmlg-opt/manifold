defmodule Manifold.Connectors.Application do
  @moduledoc false

  use Application

  alias Manifold.Connectors.ActivityLog.Handler
  alias Manifold.Connectors.ReadPush.Handler, as: ReadPushHandler

  @impl true
  def start(_type, _args) do
    Handler.attach()
    ReadPushHandler.attach()

    Supervisor.start_link([], strategy: :one_for_one, name: Manifold.Connectors.Supervisor)
  end
end

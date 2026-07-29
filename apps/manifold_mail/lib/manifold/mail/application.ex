defmodule Manifold.Mail.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Manifold.Mail.TaskSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Manifold.Mail.Supervisor)
  end
end

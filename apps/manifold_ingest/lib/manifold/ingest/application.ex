defmodule Manifold.Ingest.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:manifold_ingest, :reconciler_enabled, true) do
        [Manifold.Ingest.Reconciler]
      else
        []
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Manifold.Ingest.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

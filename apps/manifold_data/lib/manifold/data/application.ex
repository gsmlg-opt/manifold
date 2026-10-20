defmodule Manifold.Data.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [Manifold.Repo]
      |> maybe_start_styx()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Manifold.Data.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_start_styx(children) do
    if Application.get_env(:manifold_data, :oban_enabled, true) do
      children ++ [{Styx, Application.fetch_env!(:manifold_data, Styx)}]
    else
      children
    end
  end
end

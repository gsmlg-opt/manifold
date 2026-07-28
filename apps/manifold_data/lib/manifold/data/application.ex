defmodule Manifold.Data.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [Manifold.Repo]
      |> maybe_start_oban()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Manifold.Data.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_start_oban(children) do
    if Application.get_env(:manifold_data, :oban_enabled, true) do
      children ++ [{Oban, Application.fetch_env!(:manifold_data, Oban)}]
    else
      children
    end
  end
end

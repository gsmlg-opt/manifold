defmodule Manifold.SMTP.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:manifold_smtp, :enabled, true) do
        [
          {Manifold.SMTP.Admission, admission_options()},
          Manifold.SMTP.Listener.child_spec()
        ]
      else
        []
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Manifold.SMTP.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp admission_options do
    config = Application.fetch_env!(:manifold_smtp, :admission)

    [
      max_connections_per_peer: Keyword.fetch!(config, :max_connections_per_peer),
      connection_rate_limit: Keyword.fetch!(config, :connection_rate_limit),
      connection_rate_window_ms: Keyword.fetch!(config, :connection_rate_window_ms),
      transaction_rate_limit: Keyword.fetch!(config, :transaction_rate_limit),
      transaction_rate_window_ms: Keyword.fetch!(config, :transaction_rate_window_ms)
    ]
  end
end

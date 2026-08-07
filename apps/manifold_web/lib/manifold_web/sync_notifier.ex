defmodule ManifoldWeb.SyncNotifier do
  @moduledoc false

  use GenServer

  alias Manifold.Connectors
  alias Manifold.Connectors.Jobs.SyncAccount

  @handler_id "manifold-web-sync-notifier"
  @events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]
  @sync_worker inspect(SyncAccount)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec topic(Ecto.UUID.t()) :: String.t()
  def topic(account_id) when is_binary(account_id), do: "connector_sync:" <> account_id

  @impl true
  def init(_opts) do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event([:oban, :job, event], _measurements, %{job: %Oban.Job{} = job}, _config)
      when event in [:start, :stop, :exception] do
    with @sync_worker <- job.worker,
         account_id when is_binary(account_id) <- job.args["external_account_id"] do
      running? =
        case event do
          :start -> true
          _ -> Connectors.sync_job_running?(account_id)
        end

      Phoenix.PubSub.broadcast(
        Manifold.PubSub,
        topic(account_id),
        {:sync_job_changed, account_id, running?}
      )
    end

    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end

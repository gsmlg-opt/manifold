defmodule Manifold.Connectors.Jobs.SyncICloud do
  @moduledoc false
  use Oban.Worker,
    queue: :connectors,
    max_attempts: 10,
    unique: [period: 300, keys: [:connection_id, :generation], states: :incomplete]

  @impl true
  def perform(%Oban.Job{args: %{"connection_id" => id, "generation" => generation}}) do
    case Manifold.Connectors.ICloud.Sync.run(id, generation) do
      :ok ->
        :ok

      {:error, reason}
      when reason in [
             :stale,
             :disabled,
             :not_found,
             :reconnect_required,
             :account_disabled,
             :account_assignment_required
           ] ->
        {:cancel, reason}

      {:error, :busy} ->
        {:snooze, 30}

      {:error, {:rate_limited, seconds}} ->
        {:snooze, seconds}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(_), do: {:cancel, :invalid_job}
end

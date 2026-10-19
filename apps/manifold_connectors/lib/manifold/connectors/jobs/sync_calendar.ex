defmodule Manifold.Connectors.Jobs.SyncCalendar do
  @moduledoc false
  use Oban.Worker,
    queue: :connectors,
    max_attempts: 10,
    unique: [period: 300, keys: [:binding_id, :generation], states: :incomplete]

  @impl true
  def perform(%Oban.Job{args: %{"binding_id" => id, "generation" => generation}}) do
    case Manifold.Connectors.CalendarSync.run(id, generation) do
      {:ok, _} ->
        :ok

      {:error, reason}
      when reason in [
             :stale,
             :disabled,
             :not_found,
             :detached,
             :unauthorized,
             :migration_review_required
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

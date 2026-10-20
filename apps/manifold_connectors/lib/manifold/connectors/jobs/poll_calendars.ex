defmodule Manifold.Connectors.Jobs.PollCalendars do
  @moduledoc false
  use Styx.Worker, queue: :connectors, max_attempts: 3
  @impl true
  def perform(%Styx.Job{}) do
    case Manifold.Connectors.CalendarSync.enqueue_due() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

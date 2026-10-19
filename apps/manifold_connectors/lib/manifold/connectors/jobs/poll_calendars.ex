defmodule Manifold.Connectors.Jobs.PollCalendars do
  @moduledoc false
  use Oban.Worker, queue: :connectors, max_attempts: 3
  @impl true
  def perform(%Oban.Job{}) do
    case Manifold.Connectors.CalendarSync.enqueue_due() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

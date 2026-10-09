defmodule Manifold.Connectors.Jobs.PollICloud do
  @moduledoc false
  use Oban.Worker, queue: :connectors, max_attempts: 3
  @impl true
  def perform(%Oban.Job{}) do
    case Manifold.Connectors.ICloud.enqueue_due_syncs() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

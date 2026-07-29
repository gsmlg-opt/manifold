defmodule Manifold.Connectors.Jobs.PollAccounts do
  @moduledoc false

  use Oban.Worker, queue: :connectors, max_attempts: 10

  alias Manifold.Connectors

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Connectors.enqueue_due_syncs() do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Manifold.Connectors.Jobs.PollAccounts do
  @moduledoc false

  use Styx.Worker, queue: :connectors, max_attempts: 10

  alias Manifold.Connectors

  @impl Styx.Worker
  def perform(%Styx.Job{}) do
    case Connectors.enqueue_due_syncs() do
      {:ok, _count} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

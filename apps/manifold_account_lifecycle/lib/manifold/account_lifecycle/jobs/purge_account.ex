defmodule Manifold.AccountLifecycle.Jobs.PurgeAccount do
  @moduledoc false

  use Styx.Worker,
    queue: :account_purge,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:purge_id],
      states: :incomplete
    ]

  alias Manifold.AccountLifecycle.Purge

  @impl Styx.Worker
  @spec perform(Styx.Job.t()) :: Purge.result()
  def perform(%Styx.Job{args: %{"purge_id" => purge_id}} = job) do
    Purge.run(purge_id, job)
  end
end

defmodule Manifold.AccountLifecycle.Jobs.PurgeAccount do
  @moduledoc false

  use Oban.Worker,
    queue: :account_purge,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:purge_id],
      states: :incomplete
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"purge_id" => purge_id}} = job) do
    Manifold.AccountLifecycle.Purge.run(purge_id, job)
  end
end

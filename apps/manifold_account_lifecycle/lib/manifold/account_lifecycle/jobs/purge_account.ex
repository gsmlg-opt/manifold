defmodule Manifold.AccountLifecycle.Jobs.PurgeAccount do
  @moduledoc false

  @behaviour Oban.Worker

  @worker_opts [
    queue: :account_purge,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:purge_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]
  ]

  @impl Oban.Worker
  def __opts__, do: Keyword.put(@worker_opts, :worker, inspect(__MODULE__))

  @impl Oban.Worker
  def new(args, opts \\ []) when is_map(args) and is_list(opts) do
    Oban.Job.new(args, Oban.Worker.merge_opts(__opts__(), opts))
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{} = job), do: Oban.Worker.backoff(job)

  @impl Oban.Worker
  def timeout(%Oban.Job{} = job), do: Oban.Worker.timeout(job)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"purge_id" => purge_id}} = job) do
    Manifold.AccountLifecycle.Purge.run(purge_id, job)
  end
end

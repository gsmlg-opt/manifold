defmodule Manifold.Connectors.Jobs.SyncAccount do
  @moduledoc false

  use Oban.Worker,
    queue: :connectors,
    max_attempts: 20,
    unique: [
      period: 300,
      keys: [:external_account_id],
      states: :incomplete
    ]

  alias Manifold.Connectors

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"external_account_id" => account_id}}) do
    Connectors.sync_account(account_id)
  end
end

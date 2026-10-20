defmodule Manifold.Connectors.Jobs.SyncAccount do
  @moduledoc false

  use Styx.Worker,
    queue: :connectors,
    max_attempts: 20,
    unique: [
      period: 300,
      keys: [:external_account_id],
      states: :incomplete
    ]

  alias Manifold.Connectors

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"external_account_id" => account_id}}) do
    Connectors.sync_account(account_id)
  end
end

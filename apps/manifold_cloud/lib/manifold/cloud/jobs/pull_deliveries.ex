defmodule Manifold.Cloud.Jobs.PullDeliveries do
  @moduledoc false

  use Oban.Worker,
    queue: :cloud_ingress,
    max_attempts: 20,
    unique: [period: 30]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Manifold.Cloud.pull_once() do
      {:ok, _count} -> :ok
      :disabled -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

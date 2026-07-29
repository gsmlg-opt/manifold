defmodule Manifold.Cloud.Jobs.PublishRoutes do
  @moduledoc false

  use Oban.Worker,
    queue: :cloud_ingress,
    max_attempts: 10,
    unique: [period: 240]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Manifold.Cloud.publish_routes() do
      :ok -> :ok
      :disabled -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

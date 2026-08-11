defmodule Manifold.Connectors.RemoteStateJobs do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Connectors.Jobs.ApplyRemoteState
  alias Manifold.Repo

  @spec ensure(Ecto.UUID.t()) :: Oban.Job.t()
  def ensure(remote_message_id) do
    existing =
      Oban.Job
      |> where([job], job.worker == ^inspect(ApplyRemoteState))
      |> where([job], job.state in ~w(available scheduled executing retryable suspended))
      |> where(
        [job],
        fragment("?->>'remote_message_id' = ?", job.args, ^remote_message_id)
      )
      |> order_by([job], asc: job.id)
      |> limit(1)
      |> Repo.one()

    existing ||
      remote_message_id
      |> then(&ApplyRemoteState.new(%{"remote_message_id" => &1}))
      |> Repo.insert!()
  end
end

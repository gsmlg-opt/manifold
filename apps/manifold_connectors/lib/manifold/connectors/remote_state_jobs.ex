defmodule Manifold.Connectors.RemoteStateJobs do
  @moduledoc false

  alias Manifold.Connectors.Jobs.ApplyRemoteState

  @queued_unique [
    period: :infinity,
    fields: [:worker, :args],
    keys: [:remote_message_id],
    states: [:available, :scheduled, :retryable, :suspended]
  ]

  @spec ensure(Ecto.UUID.t()) :: Oban.Job.t()
  def ensure(remote_message_id) do
    %{"remote_message_id" => remote_message_id}
    |> ApplyRemoteState.new(unique: @queued_unique)
    |> Oban.insert!(retry: false)
  end
end

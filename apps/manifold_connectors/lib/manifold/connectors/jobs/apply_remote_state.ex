defmodule Manifold.Connectors.Jobs.ApplyRemoteState do
  @moduledoc false

  use Oban.Worker,
    queue: :connectors,
    max_attempts: 20,
    unique: [
      period: 300,
      keys: [:remote_message_id],
      states: :incomplete
    ]

  alias Manifold.Connectors
  alias Manifold.Core.Error

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"remote_message_id" => remote_message_id}}) do
    case Connectors.apply_remote_state(remote_message_id) do
      :ok ->
        :ok

      {:error, %Error{class: :temporary, reason: :projection_pending}} ->
        {:snooze, 5}

      {:error, %Error{class: :temporary} = error} ->
        {:error, error}

      {:error, %Error{reason: reason}} ->
        {:cancel, reason}
    end
  end
end

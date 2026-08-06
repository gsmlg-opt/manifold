defmodule Manifold.Connectors.Jobs.PushRemoteRead do
  @moduledoc false

  use Oban.Worker,
    queue: :connectors,
    max_attempts: 10,
    unique: [
      period: 60,
      keys: [:remote_message_id],
      states: :incomplete
    ]

  alias Manifold.Connectors
  alias Manifold.Connectors.Provider.Error, as: ProviderError
  alias Manifold.Core.Error

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"remote_message_id" => remote_message_id, "read" => read}})
      when is_boolean(read) do
    case Connectors.push_remote_read(remote_message_id, read) do
      :ok ->
        :ok

      {:error, %Error{class: :temporary} = error} ->
        {:error, error}

      {:error, %Error{reason: reason}} ->
        {:cancel, reason}

      {:error, %ProviderError{class: class, code: code}}
      when class in [:temporary, :reconnect] ->
        {:error, Error.new(class, code, "remote read push failed")}

      {:error, %ProviderError{code: code}} ->
        {:cancel, code}
    end
  end
end

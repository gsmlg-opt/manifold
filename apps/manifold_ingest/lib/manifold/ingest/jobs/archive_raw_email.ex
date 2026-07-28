defmodule Manifold.Ingest.Jobs.ArchiveRawEmail do
  @moduledoc """
  Archives accepted raw messages from ready spool bundles into the raw store.
  """

  use Oban.Worker, queue: :archive, max_attempts: 10

  alias Manifold.Core.Error
  alias Manifold.Ingest

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"inbound_delivery_id" => delivery_id}}) do
    case Ingest.archive_delivery(delivery_id) do
      :ok -> :ok
      {:error, %Error{class: :permanent, reason: reason}} -> {:cancel, reason}
      {:error, %Error{reason: reason}} -> {:error, reason}
    end
  end
end

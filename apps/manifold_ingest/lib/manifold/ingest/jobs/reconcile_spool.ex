defmodule Manifold.Ingest.Jobs.ReconcileSpool do
  @moduledoc """
  Scheduled Oban entry point for spool reconciliation.
  """

  use Oban.Worker, queue: :archive, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Manifold.Ingest.Reconciler.reconcile_once()
    :ok
  end
end

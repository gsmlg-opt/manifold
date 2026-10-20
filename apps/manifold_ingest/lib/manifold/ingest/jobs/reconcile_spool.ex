defmodule Manifold.Ingest.Jobs.ReconcileSpool do
  @moduledoc """
  Scheduled Styx entry point for spool reconciliation.
  """

  use Styx.Worker, queue: :archive, max_attempts: 3

  @impl Styx.Worker
  def perform(%Styx.Job{}) do
    Manifold.Ingest.Reconciler.reconcile_once()
    :ok
  end
end

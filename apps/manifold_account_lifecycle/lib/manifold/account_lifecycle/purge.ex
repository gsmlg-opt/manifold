defmodule Manifold.AccountLifecycle.Purge do
  @moduledoc false

  alias Manifold.AccountLifecycle.Schema.AccountPurge
  alias Manifold.Repo

  @spec run(Ecto.UUID.t(), Oban.Job.t()) ::
          :ok | {:snooze, 1} | {:cancel, :account_purge_not_found}
  def run(purge_id, %Oban.Job{}) do
    case Repo.get(AccountPurge, purge_id) do
      %AccountPurge{status: "completed"} -> :ok
      %AccountPurge{} -> {:snooze, 1}
      nil -> {:cancel, :account_purge_not_found}
    end
  end
end

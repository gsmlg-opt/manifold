defmodule Manifold.Data.ObanJobsTest do
  use Manifold.DataCase, async: true

  alias Manifold.Data.ObanJobs

  test "list_jobs filters by state and queue and returns newest first" do
    available = insert_job!("available", "connectors")
    completed = insert_job!("completed", "outbound")
    _other = insert_job!("completed", "connectors")

    assert Enum.map(ObanJobs.list_jobs(%{state: "available"}), & &1.id) == [available.id]

    assert Enum.map(ObanJobs.list_jobs(%{queue: "outbound"}), & &1.id) == [completed.id]

    ids = Enum.map(ObanJobs.list_jobs(%{limit: 2}), & &1.id)
    assert length(ids) == 2
    assert ids == Enum.sort(ids, :desc)
  end

  test "summary counts jobs by state" do
    insert_job!("available", "connectors")
    insert_job!("completed", "connectors")
    insert_job!("completed", "outbound")

    summary = ObanJobs.summary()

    assert summary["available"] == 1
    assert summary["completed"] == 2
    assert summary["total"] == 3
    assert summary["executing"] == 0
  end

  test "queues falls back to known names when Oban queues are disabled" do
    assert "connectors" in ObanJobs.queues()
    assert "outbound" in ObanJobs.queues()
  end

  defp insert_job!(state, queue) do
    now = DateTime.utc_now()

    attrs = %{
      state: state,
      queue: queue,
      worker: "Manifold.Connectors.Jobs.SyncAccount",
      args: %{"external_account_id" => Ecto.UUID.generate()},
      meta: %{},
      tags: [],
      errors: [],
      attempt: if(state == "completed", do: 1, else: 0),
      max_attempts: 20,
      priority: 0,
      attempted_by: [],
      inserted_at: now,
      scheduled_at: now,
      completed_at: if(state == "completed", do: now, else: nil)
    }

    %Oban.Job{}
    |> Ecto.Changeset.change(attrs)
    |> Repo.insert!()
  end
end

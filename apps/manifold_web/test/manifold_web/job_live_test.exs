defmodule ManifoldWeb.JobLiveTest do
  use ManifoldWeb.ConnCase, async: false

  alias Manifold.Repo

  test "operations shell links deliveries and jobs", %{conn: conn} do
    assert {:ok, _view, html} = live(conn, ~p"/deliveries")
    assert html =~ "ops-nav"
    assert html =~ ~s(href="/deliveries")
    assert html =~ ~s(href="/jobs")
    assert html =~ "Deliveries"
    assert html =~ "Jobs"

    assert {:ok, _view, html} = live(conn, ~p"/jobs")
    assert html =~ "Oban Jobs"
    assert html =~ "ops-nav"
    assert html =~ "is-current"
  end

  test "jobs page lists running and historical jobs with expandable details", %{conn: conn} do
    available = insert_job!("available", "connectors", %{"marker" => "running-job"})
    completed = insert_job!("completed", "outbound", %{"marker" => "history-job"})

    assert {:ok, view, html} = live(conn, ~p"/jobs")
    assert html =~ "SyncAccount"
    assert html =~ "available"
    assert html =~ "completed"
    assert html =~ "connectors"
    assert html =~ "outbound"
    assert html =~ Integer.to_string(available.id)
    assert html =~ Integer.to_string(completed.id)

    html =
      view
      |> element("#job-row-#{completed.id}")
      |> render_click()

    assert html =~ "history-job"
    assert html =~ ~s(id="job-detail-#{completed.id}")
  end

  test "jobs page filters by state", %{conn: conn} do
    available = insert_job!("available", "connectors", %{"marker" => "only-available"})
    completed = insert_job!("completed", "connectors", %{"marker" => "only-completed"})

    assert {:ok, view, _html} = live(conn, ~p"/jobs")

    html =
      view
      |> form("#jobs-filter", %{state: "available", queue: ""})
      |> render_change()

    assert html =~ ~s(id="job-row-#{available.id}")
    refute html =~ ~s(id="job-row-#{completed.id}")
  end

  defp insert_job!(state, queue, args) do
    now = DateTime.utc_now()

    attrs = %{
      state: state,
      queue: queue,
      worker: "Manifold.Connectors.Jobs.SyncAccount",
      args: args,
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

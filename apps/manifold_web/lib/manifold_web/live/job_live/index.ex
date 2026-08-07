defmodule ManifoldWeb.JobLive.Index do
  use ManifoldWeb, :live_view

  import ManifoldWeb.OperationsComponents

  alias Manifold.Data.ObanJobs

  @refresh_ms 5_000

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Jobs",
        state_filter: "",
        queue_filter: "",
        expanded_id: nil,
        queues: ObanJobs.queues(),
        states: ObanJobs.states()
      )
      |> refresh()

    if connected?(socket), do: schedule_refresh()

    {:ok, socket}
  end

  def handle_event("filter", params, socket) do
    socket =
      socket
      |> assign(
        state_filter: Map.get(params, "state", "") || "",
        queue_filter: Map.get(params, "queue", "") || "",
        expanded_id: nil
      )
      |> refresh()

    {:noreply, socket}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    job_id = String.to_integer(id)

    expanded_id =
      if socket.assigns.expanded_id == job_id do
        nil
      else
        job_id
      end

    {:noreply, assign(socket, expanded_id: expanded_id)}
  end

  def handle_info(:refresh_jobs, socket) do
    schedule_refresh()
    {:noreply, refresh(socket)}
  end

  def render(assigns) do
    ~H"""
    <.ops_shell current={:jobs}>
      <h1>Oban Jobs</h1>
      <dl class="ops-summary" aria-label="Oban jobs summary">
        <div>
          <dt>Total</dt><dd>{@summary["total"]}</dd>
        </div>
        <div>
          <dt>Executing</dt><dd>{@summary["executing"]}</dd>
        </div>
        <div>
          <dt>Available</dt><dd>{@summary["available"]}</dd>
        </div>
        <div>
          <dt>Scheduled</dt><dd>{@summary["scheduled"]}</dd>
        </div>
        <div>
          <dt>Retryable</dt><dd>{@summary["retryable"]}</dd>
        </div>
        <div>
          <dt>Completed</dt><dd>{@summary["completed"]}</dd>
        </div>
        <div>
          <dt>Discarded</dt><dd>{@summary["discarded"]}</dd>
        </div>
        <div>
          <dt>Cancelled</dt><dd>{@summary["cancelled"]}</dd>
        </div>
      </dl>

      <form id="jobs-filter" class="ops-toolbar" phx-change="filter" phx-submit="filter">
        <div class="ops-filter">
          <label for="job-state-filter">State</label>
          <select id="job-state-filter" name="state">
            <option value="" selected={@state_filter == ""}>All states</option>
            <option
              :for={state <- @states}
              value={state}
              selected={@state_filter == state}
            >
              {state}
            </option>
          </select>
        </div>
        <div class="ops-filter">
          <label for="job-queue-filter">Queue</label>
          <select id="job-queue-filter" name="queue">
            <option value="" selected={@queue_filter == ""}>All queues</option>
            <option
              :for={queue <- @queues}
              value={queue}
              selected={@queue_filter == queue}
            >
              {queue}
            </option>
          </select>
        </div>
        <button type="button" class="command-button" phx-click="refresh">Refresh</button>
      </form>

      <div class="table-scroll">
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>State</th>
              <th>Queue</th>
              <th>Worker</th>
              <th>Attempt</th>
              <th>Inserted</th>
              <th>Scheduled / Completed</th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@jobs == []}>
              <td colspan="7">No jobs match the current filters.</td>
            </tr>
            <%= for job <- @jobs do %>
              <tr
                id={"job-row-#{job.id}"}
                class={["ops-job-row", @expanded_id == job.id && "is-expanded"]}
                phx-click="toggle"
                phx-value-id={job.id}
              >
                <td>{job.id}</td>
                <td><span class={["policy-state", "state-#{job.state}"]}>{job.state}</span></td>
                <td>{job.queue}</td>
                <td>{worker_name(job.worker)}</td>
                <td>{job.attempt}/{job.max_attempts}</td>
                <td>{format_time(job.inserted_at)}</td>
                <td>{format_time(job.completed_at || job.scheduled_at)}</td>
              </tr>
              <tr :if={@expanded_id == job.id} id={"job-detail-#{job.id}"}>
                <td colspan="7">
                  <div class="ops-job-detail">
                    <h3>Args</h3>
                    <pre>{pretty_json(job.args)}</pre>
                    <h3>Errors</h3>
                    <pre>{pretty_json(job.errors)}</pre>
                  </div>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </.ops_shell>
    """
  end

  defp refresh(socket) do
    filters =
      %{}
      |> maybe_put(:state, socket.assigns.state_filter)
      |> maybe_put(:queue, socket.assigns.queue_filter)

    assign(socket, jobs: ObanJobs.list_jobs(filters), summary: ObanJobs.summary())
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh_jobs, @refresh_ms)
  end

  defp maybe_put(filters, _key, value) when value in [nil, ""], do: filters
  defp maybe_put(filters, key, value), do: Map.put(filters, key, value)

  defp worker_name(worker) when is_binary(worker) do
    worker |> String.split(".") |> List.last()
  end

  defp worker_name(worker), do: to_string(worker)

  defp format_time(nil), do: "—"

  defp format_time(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  defp format_time(%NaiveDateTime{} = datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S")
  end

  defp pretty_json(nil), do: "—"
  defp pretty_json([]), do: "[]"
  defp pretty_json(value), do: Jason.encode!(value, pretty: true)
end

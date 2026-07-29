defmodule ManifoldWeb.CloudLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.Cloud

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Cloud Ingress",
       configured?: Cloud.configured?()
     )}
  end

  @impl Phoenix.LiveView
  def handle_event("publish-routes", _params, socket) do
    {:noreply, enqueue(socket, Cloud.enqueue_route_publication(), "Route publication queued.")}
  end

  def handle_event("pull-deliveries", _params, socket) do
    {:noreply, enqueue(socket, Cloud.enqueue_pull(), "Delivery pull queued.")}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <section>
      <h1>Cloud Ingress</h1>

      <dl class="ops-summary" aria-label="Cloud ingress status">
        <div>
          <dt>Connection</dt>
          <dd>{if @configured?, do: "Configured", else: "Not configured"}</dd>
        </div>
        <div>
          <dt>Direction</dt>
          <dd>Local pull</dd>
        </div>
        <div>
          <dt>Transport</dt>
          <dd>Signed HTTPS</dd>
        </div>
      </dl>

      <div class="command-row">
        <button
          type="button"
          class="command-button"
          phx-click="publish-routes"
          disabled={!@configured?}
          title="Publish recipient routes"
        >
          Publish routes
        </button>
        <button
          type="button"
          class="command-button"
          phx-click="pull-deliveries"
          disabled={!@configured?}
          title="Pull pending deliveries"
        >
          Pull deliveries
        </button>
      </div>
    </section>
    """
  end

  defp enqueue(socket, {:ok, _job}, message), do: put_flash(socket, :info, message)

  defp enqueue(socket, :disabled, _message),
    do: put_flash(socket, :error, "Cloud ingress is not configured.")

  defp enqueue(socket, {:error, _reason}, _message),
    do: put_flash(socket, :error, "The operation could not be queued.")
end

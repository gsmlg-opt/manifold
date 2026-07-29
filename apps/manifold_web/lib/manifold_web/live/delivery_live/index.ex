defmodule ManifoldWeb.DeliveryLive.Index do
  use ManifoldWeb, :live_view

  alias Manifold.Ingest
  alias ManifoldWeb.IngestNotifier

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Manifold.PubSub, IngestNotifier.topic())

    {:ok,
     assign(socket,
       page_title: "Inbound Deliveries",
       deliveries: Ingest.list_inbound_deliveries()
     )}
  end

  def handle_info({:delivery_committed, _delivery_id}, socket) do
    {:noreply, assign(socket, :deliveries, Ingest.list_inbound_deliveries())}
  end

  def render(assigns) do
    ~H"""
    <section>
      <h1>Inbound Deliveries</h1>
      <table>
        <thead>
          <tr>
            <th>Received</th><th>Sender</th><th>Size</th><th>Raw</th><th>Processing</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={delivery <- @deliveries}>
            <td>
              <.link navigate={~p"/deliveries/#{delivery.id}"}>{Calendar.strftime(
                delivery.received_at,
                "%Y-%m-%d %H:%M:%S UTC"
              )}</.link>
            </td>
            <td>{delivery.envelope_from}</td>
            <td>{delivery.raw_size}</td>
            <td>{delivery.raw_storage_state}</td>
            <td>{delivery.processing_state}</td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end
end

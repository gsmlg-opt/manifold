defmodule ManifoldWeb.DeliveryLive.Show do
  use ManifoldWeb, :live_view

  alias Manifold.Ingest
  alias ManifoldWeb.IngestNotifier

  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Manifold.PubSub, IngestNotifier.delivery_topic(id))
    end

    detail = Ingest.get_delivery_detail!(id)
    {:ok, assign(socket, page_title: "Delivery", delivery_id: id, detail: detail)}
  end

  def handle_info(
        {:delivery_committed, delivery_id},
        %{assigns: %{delivery_id: delivery_id}} = socket
      ) do
    {:noreply, assign(socket, :detail, Ingest.get_delivery_detail!(delivery_id))}
  end

  def render(assigns) do
    ~H"""
    <section>
      <h1>Inbound Delivery</h1>
      <dl class="detail-grid">
        <dt>Envelope Sender</dt><dd>{@detail.delivery.envelope_from}</dd>
        <dt>Peer IP</dt><dd>{@detail.delivery.peer_ip}</dd>
        <dt>HELO</dt><dd>{@detail.delivery.helo}</dd>
        <dt>Received</dt><dd>
          {Calendar.strftime(@detail.delivery.received_at, "%Y-%m-%d %H:%M:%S UTC")}
        </dd>
        <dt>Raw Size</dt><dd>{@detail.delivery.raw_size}</dd>
        <dt>SHA-256</dt><dd><code>{@detail.delivery.raw_sha256}</code></dd>
        <dt>Archive State</dt><dd>{@detail.delivery.raw_storage_state}</dd>
        <dt>Processing State</dt><dd>{@detail.delivery.processing_state}</dd>
        <dt>Last Error</dt><dd>{@detail.delivery.last_error}</dd>
      </dl>

      <h2>Recipients</h2>
      <table>
        <thead>
          <tr>
            <th>Original</th><th>Canonical</th><th>Plus Tag</th><th>Mailbox ID</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={recipient <- @detail.recipients}>
            <td>{recipient.original_address}</td>
            <td>{recipient.canonical_address}</td>
            <td>{recipient.plus_tag}</td>
            <td><code>{recipient.mailbox_id}</code></td>
          </tr>
        </tbody>
      </table>

      <h2>Resolved Mailboxes</h2>
      <table>
        <thead>
          <tr>
            <th>Mailbox</th><th>Domain ID</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={mailbox <- @detail.mailboxes}>
            <td>{mailbox.display_name || mailbox.local_part}</td>
            <td><code>{mailbox.domain_id}</code></td>
          </tr>
        </tbody>
      </table>

      <h2>Operational Events</h2>
      <table>
        <thead>
          <tr>
            <th>Time</th><th>Type</th><th>Metadata</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={event <- @detail.events}>
            <td>{Calendar.strftime(event.occurred_at, "%Y-%m-%d %H:%M:%S UTC")}</td>
            <td>{event.event_type}</td>
            <td><code>{Jason.encode!(public_metadata(event.metadata))}</code></td>
          </tr>
        </tbody>
      </table>
    </section>
    """
  end

  defp public_metadata(metadata) when is_map(metadata) do
    Map.drop(metadata, [
      "raw_object_key",
      :raw_object_key,
      "spool_bundle_path",
      :spool_bundle_path
    ])
  end
end

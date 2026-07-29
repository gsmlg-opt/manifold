defmodule ManifoldWeb.DeliveryLive.Show do
  use ManifoldWeb, :live_view

  alias Manifold.Ingest
  alias Manifold.Security
  alias ManifoldWeb.IngestNotifier

  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Manifold.PubSub, IngestNotifier.delivery_topic(id))
    end

    {:ok,
     socket
     |> assign(page_title: "Delivery", delivery_id: id)
     |> refresh()}
  end

  def handle_info(
        {:delivery_committed, delivery_id},
        %{assigns: %{delivery_id: delivery_id}} = socket
      ) do
    {:noreply, refresh(socket)}
  end

  def handle_event("release", _params, %{assigns: %{assessment: assessment}} = socket)
      when not is_nil(assessment) do
    case Security.release(assessment.id) do
      {:ok, _released} ->
        {:noreply, socket |> put_flash(:info, "Quarantine released.") |> refresh()}

      {:error, error} ->
        {:noreply, put_flash(socket, :error, error.message)}
    end
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

      <h2>Security Policy</h2>
      <dl :if={@assessment} class="detail-grid security-detail">
        <dt>Evaluation</dt><dd>{@assessment.state}</dd>
        <dt>Policy</dt><dd>
          <span class={["policy-state", "state-#{@assessment.policy_action}"]}>
            {@assessment.policy_action}
          </span>
        </dd>
        <dt>Policy Applied</dt><dd>{if @assessment.policy_applied, do: "yes", else: "pending"}</dd>
        <dt>SPF</dt><dd>{@assessment.spf_result}</dd>
        <dt>DKIM</dt><dd>{@assessment.dkim_result}</dd>
        <dt>DMARC</dt><dd>{@assessment.dmarc_result}</dd>
        <dt>Malware</dt><dd>
          {@assessment.malware_verdict}
          <span :if={@assessment.malware_signature}> ({@assessment.malware_signature})</span>
        </dd>
        <dt>Spam</dt><dd>
          {@assessment.spam_verdict}
          <span :if={@assessment.spam_score}> ({@assessment.spam_score})</span>
        </dd>
        <dt>Reasons</dt><dd>{Enum.join(@assessment.policy_reasons, ", ")}</dd>
        <dt :if={@assessment.last_error_message}>Last Error</dt>
        <dd :if={@assessment.last_error_message}>
          {@assessment.last_error_class}: {@assessment.last_error_code} - {@assessment.last_error_message}
        </dd>
      </dl>
      <p :if={is_nil(@assessment)} class="policy-pending">Pending security evaluation</p>
      <button
        :if={releasable?(@assessment)}
        id="release-quarantine"
        type="button"
        class="command-button"
        phx-click="release"
      >
        Release quarantine
      </button>

      <h2>Recipients</h2>
      <div class="table-scroll">
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
      </div>

      <h2>Resolved Mailboxes</h2>
      <div class="table-scroll">
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
      </div>

      <h2>Operational Events</h2>
      <div class="table-scroll">
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
      </div>
    </section>
    """
  end

  defp refresh(socket) do
    delivery_id = socket.assigns.delivery_id
    detail = Ingest.get_delivery_detail!(delivery_id)

    assessment =
      case Security.get_assessment(delivery_id) do
        {:ok, assessment} -> assessment
        {:error, _not_found} -> nil
      end

    assign(socket, detail: detail, assessment: assessment)
  end

  defp releasable?(%{policy_action: "quarantine", policy_applied: true}), do: true
  defp releasable?(_assessment), do: false

  defp public_metadata(metadata) when is_map(metadata) do
    Map.drop(metadata, [
      "raw_object_key",
      :raw_object_key,
      "spool_bundle_path",
      :spool_bundle_path
    ])
  end
end

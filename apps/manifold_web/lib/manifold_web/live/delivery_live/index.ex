defmodule ManifoldWeb.DeliveryLive.Index do
  use ManifoldWeb, :live_view

  import ManifoldWeb.OperationsComponents

  alias Manifold.Ingest
  alias Manifold.Security
  alias ManifoldWeb.IngestNotifier

  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Manifold.PubSub, IngestNotifier.topic())

    {:ok, socket |> assign(page_title: "Inbound Deliveries") |> refresh()}
  end

  def handle_info({:delivery_committed, _delivery_id}, socket) do
    {:noreply, refresh(socket)}
  end

  def render(assigns) do
    ~H"""
    <.ops_shell current={:deliveries}>
      <h1>Inbound Deliveries</h1>
      <dl class="ops-summary" aria-label="Inbound operations summary">
        <div>
          <dt>Total</dt><dd>{@summary.total}</dd>
        </div>
        <div>
          <dt>Pending policy</dt><dd>{@summary.pending}</dd>
        </div>
        <div>
          <dt>Quarantined</dt><dd>{@summary.quarantined}</dd>
        </div>
        <div>
          <dt>Unarchived</dt><dd>{@summary.unarchived}</dd>
        </div>
        <div>
          <dt>Failed</dt><dd>{@summary.failed}</dd>
        </div>
      </dl>

      <div class="table-scroll">
        <table>
          <thead>
            <tr>
              <th>Received</th><th>Source</th><th>Sender</th><th>Size</th><th>Raw</th><th>
                Processing
              </th><th>
                Policy
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows}>
              <td>
                <.link navigate={~p"/deliveries/#{row.delivery.id}"}>{Calendar.strftime(
                  row.delivery.received_at,
                  "%Y-%m-%d %H:%M:%S UTC"
                )}</.link>
              </td>
              <td>{source_label(row.delivery.source_kind)}</td>
              <td>{row.delivery.envelope_from || "Not applicable"}</td>
              <td>{row.delivery.raw_size}</td>
              <td>{row.delivery.raw_storage_state}</td>
              <td>{row.delivery.processing_state}</td>
              <td><span class={["policy-state", "state-#{row.policy}"]}>{row.policy}</span></td>
            </tr>
          </tbody>
        </table>
      </div>
    </.ops_shell>
    """
  end

  defp refresh(socket) do
    deliveries = Ingest.list_inbound_deliveries()
    assessments = Security.assessments_by_delivery(Enum.map(deliveries, & &1.id))

    rows =
      Enum.map(deliveries, fn delivery ->
        assessment = Map.get(assessments, delivery.id)
        %{delivery: delivery, assessment: assessment, policy: policy_state(assessment)}
      end)

    summary = %{
      total: length(rows),
      pending: Enum.count(rows, &(&1.policy == "pending")),
      quarantined: Enum.count(rows, &(&1.policy == "quarantine")),
      unarchived: Enum.count(rows, &(&1.delivery.raw_storage_state != "archived")),
      failed:
        Enum.count(
          rows,
          &(&1.delivery.processing_state == "failed" or &1.policy == "failed")
        )
    }

    assign(socket, rows: rows, summary: summary)
  end

  defp policy_state(nil), do: "pending"
  defp policy_state(%{state: "failed"}), do: "failed"
  defp policy_state(%{policy_applied: false}), do: "pending"
  defp policy_state(%{policy_action: action}), do: action

  defp source_label("smtp"), do: "SMTP"
  defp source_label("edge_smtp"), do: "Cloud edge"
  defp source_label("provider_import"), do: "Provider"
  defp source_label(source), do: source
end

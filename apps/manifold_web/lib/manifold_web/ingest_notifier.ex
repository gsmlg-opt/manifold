defmodule ManifoldWeb.IngestNotifier do
  @moduledoc false

  use GenServer

  @handler_id "manifold-web-ingest-notifier"
  @topic "inbound_deliveries"
  @events [
    [:manifold, :ingest, :accept, :stop],
    [:manifold, :ingest, :archive, :stop],
    [:manifold, :ingest, :security, :stop],
    [:manifold, :security, :policy, :committed],
    [:manifold, :security, :evaluation, :failed]
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec delivery_topic(Ecto.UUID.t()) :: String.t()
  def delivery_topic(delivery_id), do: @topic <> ":" <> delivery_id

  @impl true
  def init(_opts) do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event(_event, _measurements, %{delivery_id: delivery_id}, _config) do
    message = {:delivery_committed, delivery_id}
    Phoenix.PubSub.broadcast(Manifold.PubSub, @topic, message)
    Phoenix.PubSub.broadcast(Manifold.PubSub, delivery_topic(delivery_id), message)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end

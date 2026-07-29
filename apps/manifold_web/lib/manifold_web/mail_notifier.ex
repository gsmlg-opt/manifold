defmodule ManifoldWeb.MailNotifier do
  @moduledoc false

  use GenServer

  @handler_id "manifold-web-mail-notifier"
  @events [
    [:manifold, :mail, :projection, :stop],
    [:manifold, :mail, :mailbox, :changed]
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec mailbox_topic(Ecto.UUID.t()) :: String.t()
  def mailbox_topic(mailbox_id), do: "mailbox:" <> mailbox_id

  @impl true
  def init(_opts) do
    :telemetry.detach(@handler_id)
    :ok = :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
    {:ok, nil}
  end

  @impl true
  def terminate(_reason, _state), do: :telemetry.detach(@handler_id)

  @doc false
  def handle_event(
        [:manifold, :mail, :projection, :stop],
        _measurements,
        %{mailbox_ids: mailbox_ids},
        _config
      ) do
    Enum.each(mailbox_ids, &broadcast/1)
  end

  def handle_event(
        [:manifold, :mail, :mailbox, :changed],
        _measurements,
        %{mailbox_id: mailbox_id},
        _config
      ) do
    broadcast(mailbox_id)
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp broadcast(mailbox_id) do
    Phoenix.PubSub.broadcast(
      Manifold.PubSub,
      mailbox_topic(mailbox_id),
      {:mailbox_changed, mailbox_id}
    )
  end
end

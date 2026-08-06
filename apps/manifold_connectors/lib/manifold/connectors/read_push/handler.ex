defmodule Manifold.Connectors.ReadPush.Handler do
  @moduledoc false

  alias Manifold.Connectors

  @handler_id "manifold-connectors-read-push"
  @event [:manifold, :mail, :mailbox, :read_changed]

  @spec attach() :: :ok
  def attach do
    detach()

    :ok =
      :telemetry.attach(
        @handler_id,
        @event,
        &__MODULE__.handle_event/4,
        %{}
      )

    :ok
  end

  @spec detach() :: :ok
  def detach do
    :telemetry.detach(@handler_id)
    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc false
  def handle_event(@event, _measurements, metadata, _config) when is_map(metadata) do
    entry_ids = metadata[:entry_ids] || metadata["entry_ids"] || []

    read? =
      cond do
        is_boolean(metadata[:read?]) -> metadata[:read?]
        is_boolean(metadata["read?"]) -> metadata["read?"]
        true -> nil
      end

    if is_list(entry_ids) and entry_ids != [] and is_boolean(read?) do
      _ = Connectors.enqueue_read_push(entry_ids, read?)
    end

    :ok
  rescue
    _ -> :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
end

defmodule Manifold.Connectors.ActivityLog.Handler do
  @moduledoc false

  alias Manifold.Connectors.ActivityLog

  @handler_id "manifold-connectors-activity-log"
  @events [
    [:manifold, :connectors, :imap, :connect, :stop],
    [:manifold, :connectors, :imap, :auth, :stop],
    [:manifold, :connectors, :imap, :select, :stop],
    [:manifold, :connectors, :sync, :stop],
    [:manifold, :connectors, :sync, :message, :stop]
  ]

  @allowed_metadata [
    :account_id,
    :host,
    :port,
    :tls_mode,
    :username,
    :mailbox_path,
    :uidvalidity,
    :provider,
    :provider_message_id,
    :result,
    :error_code,
    :error_message
  ]

  @spec attach() :: :ok
  def attach do
    detach()

    :ok =
      :telemetry.attach_many(
        @handler_id,
        @events,
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
  def handle_event(event, measurements, metadata, _config)
      when is_list(event) and is_map(measurements) and is_map(metadata) do
    account_id = metadata[:account_id] || metadata["account_id"]

    with {:ok, account_id} <- ActivityLog.validate_account_id(account_id) do
      entry = %{
        "event" => Enum.map(event, &to_string/1),
        "timestamp" =>
          DateTime.utc_now() |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601(),
        "measurements" => normalize_measurements(measurements),
        "metadata" => normalize_metadata(metadata, account_id)
      }

      _ = ActivityLog.append(account_id, entry)
      _ = ActivityLog.prune(account_id)
    end

    :ok
  rescue
    _ -> :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp normalize_measurements(measurements) do
    measurements
    |> Map.take([
      :duration_ms,
      :message_count,
      :page_count,
      "duration_ms",
      "message_count",
      "page_count"
    ])
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp normalize_metadata(metadata, account_id) do
    metadata
    |> Map.take(@allowed_metadata ++ Enum.map(@allowed_metadata, &to_string/1))
    |> Map.put(:account_id, account_id)
    |> Map.new(fn {k, v} -> {to_string(k), normalize_value(v)} end)
  end

  defp normalize_value(v) when is_atom(v), do: Atom.to_string(v)
  defp normalize_value(v), do: v
end

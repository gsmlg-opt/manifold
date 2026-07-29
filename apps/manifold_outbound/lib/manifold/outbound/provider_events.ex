defmodule Manifold.Outbound.ProviderEvents do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Core.Error
  alias Manifold.Outbound.Provider

  alias Manifold.Outbound.Schema.{
    OutboundRecipient,
    ProviderEvent,
    ProviderSubmission
  }

  alias Manifold.Outbound.State
  alias Manifold.Repo

  @spec record(String.t(), Provider.Event.t(), Keyword.t()) ::
          {:ok, :processed | :unmatched | :duplicate} | {:error, Error.t() | Ecto.Changeset.t()}
  def record(provider, %Provider.Event{} = incoming, opts \\ []) when is_binary(provider) do
    result =
      Repo.transaction(fn ->
        lock_event(provider, incoming.provider_event_id)

        case Repo.get_by(ProviderEvent,
               provider: provider,
               provider_event_id: incoming.provider_event_id
             ) do
          %ProviderEvent{} ->
            :duplicate

          nil ->
            persist_new_event(provider, incoming, opts)
        end
      end)

    case result do
      {:ok, outcome} -> {:ok, outcome}
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, database_error(reason)}
    end
  rescue
    DBConnection.ConnectionError -> {:error, database_error(:unavailable)}
  end

  @spec reconcile_pending(String.t(), String.t(), Ecto.UUID.t(), DateTime.t()) :: :ok
  def reconcile_pending(provider, provider_message_id, outbound_message_id, now) do
    ProviderEvent
    |> where(
      [event],
      event.provider == ^provider and event.provider_message_id == ^provider_message_id and
        event.processing_state == "unmatched"
    )
    |> order_by([event], asc: event.occurred_at, asc: event.provider_event_id)
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.each(fn event ->
      apply_event(event, outbound_message_id, now)
    end)

    :ok
  end

  defp persist_new_event(provider, incoming, opts) do
    now = DateTime.utc_now()

    submission =
      Repo.get_by(ProviderSubmission,
        provider: provider,
        provider_message_id: incoming.provider_message_id
      )

    state = if submission, do: "pending", else: "unmatched"

    event =
      %ProviderEvent{}
      |> ProviderEvent.changeset(%{
        outbound_message_id: submission && submission.outbound_message_id,
        provider: provider,
        provider_event_id: incoming.provider_event_id,
        provider_message_id: incoming.provider_message_id,
        event_type: incoming.event_type,
        normalized_state: incoming.normalized_state,
        metadata: Map.put(incoming.metadata, "recipient_addresses", incoming.recipient_addresses),
        occurred_at: incoming.occurred_at,
        received_at: now,
        processing_state: state
      })
      |> Repo.insert!()

    maybe_fail!(opts, :after_event_before_recipient_update)

    if submission do
      apply_event(event, submission.outbound_message_id, now)
      :processed
    else
      :unmatched
    end
  end

  defp apply_event(event, outbound_message_id, now) do
    addresses = Map.get(event.metadata, "recipient_addresses", [])

    OutboundRecipient
    |> where(
      [recipient],
      recipient.outbound_message_id == ^outbound_message_id and
        recipient.canonical_address in ^addresses
    )
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.each(fn recipient ->
      {:ok, {state, last_event_at}} =
        State.apply_recipient_event(
          recipient.delivery_state,
          recipient.last_event_at,
          event.normalized_state,
          event.occurred_at
        )

      if state != recipient.delivery_state or last_event_at != recipient.last_event_at do
        recipient
        |> Ecto.Changeset.change(delivery_state: state, last_event_at: last_event_at)
        |> Repo.update!()
      end
    end)

    event
    |> Ecto.Changeset.change(
      outbound_message_id: outbound_message_id,
      processing_state: "processed",
      processed_at: now,
      last_error: nil
    )
    |> Repo.update!()
  end

  defp lock_event(provider, event_id) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [provider <> ":" <> event_id])
  end

  defp maybe_fail!(opts, boundary) do
    if Keyword.get(opts, :fail_at) == boundary do
      Repo.rollback(Error.new(:temporary, boundary, "injected provider-event failure"))
    end
  end

  defp database_error(reason) do
    Error.new(:temporary, :database_unavailable, "provider-event database operation failed", %{
      reason: inspect(reason)
    })
  end
end

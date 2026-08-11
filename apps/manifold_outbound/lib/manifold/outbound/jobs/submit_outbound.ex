defmodule Manifold.Outbound.Jobs.SubmitOutbound do
  @moduledoc false

  alias Manifold.Core.Error
  alias Manifold.Outbound
  alias Manifold.Outbound.Provider

  use Oban.Worker,
    queue: :outbound,
    max_attempts: 8,
    unique: [
      period: :infinity,
      keys: [:outbound_message_id],
      states: :incomplete
    ]

  @impl true
  def perform(%Oban.Job{args: %{"outbound_message_id" => outbound_message_id}}) do
    case Outbound.submit_message(outbound_message_id) do
      :ok ->
        :ok

      {:error,
       %Provider.Error{
         class: :transient,
         retry_after: retry_after
       }}
      when is_integer(retry_after) and retry_after >= 0 ->
        {:snooze, retry_after}

      {:error, %Provider.Error{class: :transient, code: code}} ->
        {:error, code}

      {:error, %Provider.Error{class: :permanent}} ->
        :ok

      {:error, %Error{class: :temporary, reason: reason}} ->
        {:error, Atom.to_string(reason)}

      {:error, %Error{class: :permanent, reason: :submission_uncertain}} ->
        :ok

      {:error, %Error{class: :permanent, reason: reason}} ->
        {:cancel, Atom.to_string(reason)}
    end
  end

  @impl true
  def backoff(%Oban.Job{attempt: attempt}), do: min(300 * attempt * attempt, 7_200)
end

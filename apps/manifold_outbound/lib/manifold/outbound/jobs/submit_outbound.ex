defmodule Manifold.Outbound.Jobs.SubmitOutbound do
  @moduledoc false

  alias Manifold.Core.Error
  alias Manifold.Outbound
  alias Manifold.Outbound.Provider

  @submission_attempt_limit 8

  use Oban.Worker,
    queue: :outbound,
    max_attempts: @submission_attempt_limit,
    unique: [
      period: :infinity,
      keys: [:outbound_message_id],
      states: :incomplete
    ]

  @impl true
  def perform(%Oban.Job{args: %{"outbound_message_id" => outbound_message_id}} = job) do
    case Ecto.UUID.cast(outbound_message_id) do
      {:ok, outbound_message_id} -> perform_valid(job, outbound_message_id)
      :error -> {:cancel, "outbound_not_found"}
    end
  end

  defp perform_valid(job, outbound_message_id) do
    case Outbound.submit_message(outbound_message_id, retry_exhausted?: final_attempt?(job)) do
      :ok ->
        :ok

      {:error, %Provider.Error{class: :transient} = error} ->
        retry_transient(error)

      {:error, %Provider.Error{class: :uncertain}} ->
        :ok

      {:error, %Provider.Error{class: :permanent}} ->
        :ok

      {:error, %Error{class: :permanent, reason: :submission_uncertain}} ->
        :ok

      {:error, %Error{class: :temporary, reason: reason}} ->
        {:error, Atom.to_string(reason)}

      {:error, %Error{class: :permanent, reason: reason}} ->
        {:cancel, Atom.to_string(reason)}
    end
  end

  @impl true
  def backoff(%Oban.Job{attempt: attempt}), do: min(300 * attempt * attempt, 7_200)

  defp retry_transient(%Provider.Error{retry_after: retry_after})
       when is_integer(retry_after) and retry_after >= 0,
       do: {:snooze, retry_after}

  defp retry_transient(%Provider.Error{code: code}), do: {:error, code}

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts}) do
    attempt >= min(max_attempts, @submission_attempt_limit)
  end
end

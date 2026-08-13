defmodule Manifold.Outbound.Jobs.SubmitOutbound do
  @moduledoc false

  alias Manifold.Core.Error
  alias Manifold.Outbound
  alias Manifold.Outbound.Provider

  @submission_attempt_limit 8
  @cleanup_attempt @submission_attempt_limit + 1
  @cleanup_snooze_seconds 7_200

  use Oban.Worker,
    queue: :outbound,
    max_attempts: @cleanup_attempt,
    unique: [
      period: :infinity,
      keys: [:outbound_message_id],
      states: :incomplete
    ]

  @impl true
  def perform(%Oban.Job{} = job), do: perform(job, [])

  @doc false
  def perform(
        %Oban.Job{args: %{"outbound_message_id" => outbound_message_id}} = job,
        opts
      )
      when is_list(opts) do
    case Ecto.UUID.cast(outbound_message_id) do
      {:ok, outbound_message_id} ->
        if cleanup_attempt?(job) do
          perform_cleanup(job, outbound_message_id, opts)
        else
          perform_submission(job, outbound_message_id, opts)
        end

      :error ->
        {:cancel, "outbound_not_found"}
    end
  end

  defp perform_submission(job, outbound_message_id, opts) do
    submit_opts = Keyword.put(opts, :provider_attempt_limit, @submission_attempt_limit)

    if final_raw_attempt?(job) do
      try do
        outbound_message_id
        |> Outbound.submit_message(submit_opts)
        |> handle_cleanup_result(job)
      rescue
        _exception -> {:snooze, cleanup_backoff(job)}
      end
    else
      outbound_message_id
      |> Outbound.submit_message(submit_opts)
      |> handle_submission_result()
    end
  end

  defp perform_cleanup(job, outbound_message_id, opts) do
    submit_opts =
      opts
      |> Keyword.put(:cleanup?, true)
      |> Keyword.put(:provider_attempt_limit, @submission_attempt_limit)

    try do
      outbound_message_id
      |> Outbound.submit_message(submit_opts)
      |> handle_cleanup_result(job)
    rescue
      _exception -> {:snooze, cleanup_backoff(job)}
    end
  end

  defp handle_submission_result(result) do
    case result do
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

  defp handle_cleanup_result({:error, %Provider.Error{class: :transient} = error}, job) do
    case error.retry_after do
      retry_after when is_integer(retry_after) and retry_after >= 0 ->
        {:snooze, retry_after}

      _missing_or_invalid_retry_after ->
        {:snooze, cleanup_backoff(job)}
    end
  end

  defp handle_cleanup_result({:error, %Error{class: :temporary}}, job),
    do: {:snooze, cleanup_backoff(job)}

  defp handle_cleanup_result(result, _job), do: handle_submission_result(result)

  @impl true
  def backoff(%Oban.Job{attempt: attempt}), do: min(300 * attempt * attempt, 7_200)

  defp retry_transient(%Provider.Error{retry_after: retry_after})
       when is_integer(retry_after) and retry_after >= 0,
       do: {:snooze, retry_after}

  defp retry_transient(%Provider.Error{code: code}), do: {:error, code}

  defp cleanup_attempt?(%Oban.Job{attempt: attempt}), do: attempt >= @cleanup_attempt

  defp final_raw_attempt?(%Oban.Job{attempt: attempt}),
    do: attempt >= @submission_attempt_limit

  defp cleanup_backoff(%Oban.Job{} = job), do: max(backoff(job), @cleanup_snooze_seconds)
end

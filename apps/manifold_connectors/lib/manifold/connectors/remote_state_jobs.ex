defmodule Manifold.Connectors.RemoteStateJobs do
  @moduledoc false

  alias Manifold.Connectors.Jobs.ApplyRemoteState

  @queued_unique [
    period: :infinity,
    fields: [:worker, :args],
    keys: [:remote_message_id],
    states: [:available, :scheduled, :retryable, :suspended]
  ]

  @insert_retry_attempts 100
  @insert_retry_delay_ms 10

  @spec ensure(Ecto.UUID.t()) :: Oban.Job.t()
  def ensure(remote_message_id) do
    insert_until_persisted(remote_message_id, @insert_retry_attempts)
  end

  defp insert_until_persisted(remote_message_id, attempts_left) do
    %{"remote_message_id" => remote_message_id}
    |> ApplyRemoteState.new(unique: @queued_unique)
    |> insert_job!()
    |> case do
      %Oban.Job{id: nil} when attempts_left > 1 ->
        Process.sleep(@insert_retry_delay_ms)
        insert_until_persisted(remote_message_id, attempts_left - 1)

      %Oban.Job{id: nil} ->
        raise "remote-state job insertion remained contended"

      %Oban.Job{id: id} = job when is_integer(id) ->
        job
    end
  end

  defp insert_job!(changeset) do
    case Oban.Registry.lookup(Oban) do
      nil -> insert_with_config!(changeset)
      {_pid, _config} -> Oban.insert!(changeset, retry: false)
    end
  end

  defp insert_with_config!(changeset) do
    config =
      :manifold_data
      |> Application.fetch_env!(Oban)
      |> Keyword.put(:insert_trigger, false)
      |> Oban.Config.new()

    case Oban.Engine.insert_job(config, changeset, retry: false) do
      {:ok, job} ->
        job

      {:error, %Ecto.Changeset{} = changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset

      {:error, reason} ->
        raise RuntimeError, inspect(reason)
    end
  end
end

defmodule Manifold.Data.ObanJobs do
  @moduledoc """
  Read-only helpers for listing and summarizing Oban jobs.
  """

  import Ecto.Query

  alias Manifold.Repo

  @states ~w(available scheduled executing retryable completed discarded cancelled)
  @default_limit 50

  @type filters :: %{
          optional(:state) => String.t() | [String.t()],
          optional(:queue) => String.t(),
          optional(:limit) => pos_integer()
        }

  @spec states() :: [String.t()]
  def states, do: @states

  @default_queues ~w(archive mail_parse security outbound cloud_ingress connectors account_purge)

  @spec queues() :: [String.t()]
  def queues do
    case :manifold_data |> Application.get_env(Oban, []) |> Keyword.get(:queues, []) do
      queues when is_list(queues) and queues != [] ->
        queues
        |> Enum.map(fn
          {name, _concurrency} -> to_string(name)
          name when is_atom(name) -> to_string(name)
          name when is_binary(name) -> name
        end)
        |> Enum.sort()

      _disabled_or_empty ->
        @default_queues
    end
  end

  @spec list_jobs(filters()) :: [Oban.Job.t()]
  def list_jobs(filters \\ %{}) do
    limit = Map.get(filters, :limit, @default_limit)

    Oban.Job
    |> filter_state(filters)
    |> filter_queue(filters)
    |> order_by([job], desc: job.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec summary() :: %{String.t() => non_neg_integer()}
  def summary do
    counts =
      Oban.Job
      |> group_by([job], job.state)
      |> select([job], {job.state, count(job.id)})
      |> Repo.all()
      |> Map.new()

    base = Map.new(@states, fn state -> {state, Map.get(counts, state, 0)} end)
    Map.put(base, "total", counts |> Map.values() |> Enum.sum())
  end

  defp filter_state(query, filters) do
    case normalize_states(Map.get(filters, :state)) do
      [] -> query
      states -> where(query, [job], job.state in ^states)
    end
  end

  defp filter_queue(query, filters) do
    case Map.get(filters, :queue) do
      queue when is_binary(queue) and queue != "" ->
        where(query, [job], job.queue == ^queue)

      _other ->
        query
    end
  end

  defp normalize_states(nil), do: []
  defp normalize_states(""), do: []
  defp normalize_states(state) when is_binary(state), do: [state]

  defp normalize_states(states) when is_list(states) do
    Enum.filter(states, &(is_binary(&1) and &1 != ""))
  end
end

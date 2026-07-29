defmodule Manifold.Cloud do
  @moduledoc """
  Public local APIs for route publication and edge delivery synchronization.
  """

  alias Manifold.Accounts
  alias Manifold.Cloud.{Client, Synchronizer}
  alias Manifold.Cloud.Jobs.{PublishRoutes, PullDeliveries}

  @spec publish_routes(keyword()) :: :ok | :disabled | {:error, term()}
  def publish_routes(opts \\ []) do
    source = Keyword.get(opts, :source, configured_source())
    accounts = Keyword.get(opts, :accounts, Accounts)
    client = Keyword.get(opts, :client, Client)
    client_opts = Keyword.get(opts, :client_opts, [])

    if source do
      with {:ok, snapshot} <- accounts.recipient_snapshot(),
           :ok <- client.publish_snapshot(source, snapshot, client_opts) do
        :ok
      end
    else
      :disabled
    end
  end

  @spec pull_once(keyword()) :: {:ok, non_neg_integer()} | :disabled | {:error, term()}
  def pull_once(opts \\ []) do
    source = Keyword.get(opts, :source, configured_source())
    client = Keyword.get(opts, :client, Client)
    synchronizer = Keyword.get(opts, :synchronizer, Synchronizer)
    client_opts = Keyword.get(opts, :client_opts, [])

    if source do
      with {:ok, deliveries} <- client.list_deliveries(source, client_opts) do
        Enum.reduce_while(deliveries, {:ok, 0}, fn delivery, {:ok, count} ->
          sync_opts =
            opts
            |> Keyword.get(:synchronizer_opts, [])
            |> Keyword.put(:client, client)
            |> Keyword.put(:client_opts, client_opts)

          handle_delivery_result(
            synchronizer.sync_delivery(source, delivery, sync_opts),
            source,
            delivery,
            client,
            client_opts,
            count
          )
        end)
      end
    else
      :disabled
    end
  end

  @spec configured?() :: boolean()
  def configured?, do: not is_nil(configured_source())

  @spec enqueue_route_publication() :: {:ok, Oban.Job.t()} | {:error, term()} | :disabled
  def enqueue_route_publication do
    if configured?() do
      %{}
      |> PublishRoutes.new()
      |> Oban.insert()
    else
      :disabled
    end
  end

  @spec enqueue_pull() :: {:ok, Oban.Job.t()} | {:error, term()} | :disabled
  def enqueue_pull do
    if configured?() do
      %{}
      |> PullDeliveries.new()
      |> Oban.insert()
    else
      :disabled
    end
  end

  defp configured_source, do: Application.get_env(:manifold_cloud, :source)

  defp handle_delivery_result(:ok, _source, _delivery, _client, _client_opts, count) do
    {:cont, {:ok, count + 1}}
  end

  defp handle_delivery_result(
         {:error, %Manifold.Core.Error{class: :permanent, reason: reason}},
         source,
         %{"edge_delivery_id" => edge_delivery_id, "raw_sha256" => raw_sha256},
         client,
         client_opts,
         count
       ) do
    case client.report_failure(
           source,
           edge_delivery_id,
           raw_sha256,
           reason,
           client_opts
         ) do
      :ok -> {:cont, {:ok, count}}
      {:error, _reason} = failure -> {:halt, failure}
    end
  end

  defp handle_delivery_result(
         {:error, _reason} = failure,
         _source,
         _delivery,
         _client,
         _client_opts,
         _count
       ) do
    {:halt, failure}
  end
end

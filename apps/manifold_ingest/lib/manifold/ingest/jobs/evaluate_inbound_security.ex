defmodule Manifold.Ingest.Jobs.EvaluateInboundSecurity do
  @moduledoc """
  Evaluates an archived inbound delivery through the configured security adapters.
  """

  use Oban.Worker,
    queue: :security,
    max_attempts: 10,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:inbound_delivery_id, :evaluation_version],
      states: :incomplete
    ]

  alias Manifold.Core.Error
  alias Manifold.Ingest

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "inbound_delivery_id" => delivery_id,
            "evaluation_version" => evaluation_version
          } = args
      }) do
    opts =
      [
        evaluation_version: evaluation_version,
        adapter_config: Application.get_env(:manifold_security, :adapter_config, [])
      ]
      |> add_configured_adapter(:authentication_adapter, args)
      |> add_configured_adapter(:malware_adapter, args)
      |> add_configured_adapter(:spam_adapter, args)

    case Ingest.evaluate_security(delivery_id, opts) do
      :ok -> :ok
      {:error, %Error{class: :permanent, reason: reason}} -> {:cancel, reason}
      {:error, %Error{reason: reason}} -> {:error, reason}
    end
  end

  defp add_configured_adapter(opts, key, _args) do
    case Application.get_env(:manifold_security, key) do
      nil -> opts
      adapter -> Keyword.put(opts, key, adapter)
    end
  end
end

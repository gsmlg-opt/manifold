defmodule Manifold.Ingest.Jobs.ProjectInboundMail do
  @moduledoc """
  Projects an archived inbound delivery into mailbox-visible normalized mail.
  """

  use Oban.Worker,
    queue: :mail_parse,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:inbound_delivery_id, :parser_version, :sanitizer_version],
      states: :incomplete
    ]

  alias Manifold.Core.Error
  alias Manifold.Ingest

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"inbound_delivery_id" => delivery_id} = args}) do
    parser_version = Map.get(args, "parser_version", parser_version())
    sanitizer_version = Map.get(args, "sanitizer_version", sanitizer_version())

    case Ingest.project_delivery(delivery_id,
           parser_version: parser_version,
           sanitizer_version: sanitizer_version
         ) do
      :ok -> :ok
      {:error, %Error{class: :permanent, reason: reason}} -> {:cancel, reason}
      {:error, %Error{reason: reason}} -> {:error, reason}
    end
  end

  defp parser_version, do: Application.get_env(:manifold_mail, :parser_version, 1)
  defp sanitizer_version, do: Application.get_env(:manifold_mail, :sanitizer_version, 1)
end

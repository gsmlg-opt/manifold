defmodule Manifold.Mail.ReceivedAt do
  @moduledoc false

  import Ecto.Query

  alias Manifold.Mail.Schema.{MailboxEntry, Message, Thread}
  alias Manifold.Repo

  @spec set(Ecto.UUID.t(), DateTime.t()) :: :ok
  def set(inbound_delivery_id, %DateTime{} = received_at)
      when is_binary(inbound_delivery_id) do
    received_at = ensure_usec(received_at)

    case Repo.get_by(Message, inbound_delivery_id: inbound_delivery_id) do
      %Message{} = message ->
        if is_nil(message.received_at) or
             DateTime.compare(message.received_at, received_at) != :eq do
          message
          |> Message.changeset(%{received_at: received_at})
          |> Repo.update!()
        end

        Repo.query!(
          """
          UPDATE inbound_deliveries
          SET received_at = $1, updated_at = $1
          WHERE id = $2::uuid
          """,
          [received_at, Ecto.UUID.dump!(inbound_delivery_id)]
        )

        refresh_threads(inbound_delivery_id)
        :ok

      nil ->
        :ok
    end
  end

  defp refresh_threads(inbound_delivery_id) do
    thread_ids =
      MailboxEntry
      |> where([entry], entry.inbound_delivery_id == ^inbound_delivery_id)
      |> where([entry], not is_nil(entry.thread_id))
      |> select([entry], entry.thread_id)
      |> distinct(true)
      |> Repo.all()

    Enum.each(thread_ids, &refresh_thread/1)
  end

  defp refresh_thread(thread_id) do
    %{count: count, last_message_at: last_message_at} =
      from(entry in MailboxEntry,
        join: message in Message,
        on: message.id == entry.message_id,
        where: entry.thread_id == ^thread_id,
        select: %{
          count: count(entry.id),
          last_message_at:
            max(
              fragment(
                "COALESCE(?, ?, ?)",
                message.received_at,
                message.sent_at,
                entry.inserted_at
              )
            )
        }
      )
      |> Repo.one!()

    thread = Repo.get!(Thread, thread_id)

    thread
    |> Thread.changeset(%{message_count: count, last_message_at: last_message_at})
    |> Repo.update!()
  end

  defp ensure_usec(%DateTime{microsecond: {us, _}} = datetime),
    do: %{datetime | microsecond: {us, 6}}
end

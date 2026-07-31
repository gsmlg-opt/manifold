defmodule ManifoldAPI.GraphQL.Resolvers do
  @moduledoc false

  alias Manifold.Core.Error
  alias ManifoldAPI.Mail

  def health(_parent, _args, _resolution), do: {:ok, Mail.health()}

  def mailboxes(_parent, _args, _resolution) do
    Mail.list_mailboxes()
  end

  def folders(_parent, %{mailbox_id: mailbox_id}, _resolution) do
    mailbox_id
    |> Mail.list_folders()
    |> map_error()
  end

  def conversations(_parent, args, _resolution) do
    opts =
      []
      |> maybe_put(:after, Map.get(args, :after))
      |> maybe_put(:limit, Map.get(args, :limit))
      |> maybe_put(:q, Map.get(args, :q))

    args.mailbox_id
    |> Mail.list_conversations(args.folder_id, opts)
    |> map_error()
  end

  def search(_parent, args, _resolution) do
    opts =
      []
      |> maybe_put(:after, Map.get(args, :after))
      |> maybe_put(:limit, Map.get(args, :limit))

    args.mailbox_id
    |> Mail.search(args.q, opts)
    |> map_error()
  end

  def conversation(_parent, %{mailbox_id: mailbox_id, thread_id: thread_id}, _resolution) do
    mailbox_id
    |> Mail.get_conversation(thread_id)
    |> map_error()
  end

  def message_body(_parent, %{mailbox_id: mailbox_id, message_id: message_id}, _resolution) do
    mailbox_id
    |> Mail.get_message_body(message_id)
    |> map_error()
  end

  defp map_error({:ok, value}), do: {:ok, value}

  defp map_error({:error, %Error{} = error}) do
    {:error,
     %{
       message: error.message,
       extensions: %{
         reason: to_string(error.reason),
         class: to_string(error.class)
       }
     }}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end

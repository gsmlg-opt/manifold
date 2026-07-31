defmodule ManifoldAPI.GraphQL.Schema do
  @moduledoc false

  use Absinthe.Schema

  alias ManifoldAPI.GraphQL.Resolvers

  import_types(ManifoldAPI.GraphQL.Types)

  query do
    @desc "API health status"
    field :health, non_null(:health) do
      resolve(&Resolvers.health/3)
    end

    @desc "List all mailboxes"
    field :mailboxes, non_null(list_of(non_null(:mailbox))) do
      resolve(&Resolvers.mailboxes/3)
    end

    @desc "List folders for a mailbox"
    field :folders, non_null(list_of(non_null(:folder))) do
      arg(:mailbox_id, non_null(:id))
      resolve(&Resolvers.folders/3)
    end

    @desc "List conversations in a folder"
    field :conversations, non_null(:conversation_page) do
      arg(:mailbox_id, non_null(:id))
      arg(:folder_id, non_null(:id))
      arg(:after, :string)
      arg(:limit, :integer)
      arg(:q, :string)
      resolve(&Resolvers.conversations/3)
    end

    @desc "Search conversations in a mailbox inbox"
    field :search, non_null(:conversation_page) do
      arg(:mailbox_id, non_null(:id))
      arg(:q, non_null(:string))
      arg(:after, :string)
      arg(:limit, :integer)
      resolve(&Resolvers.search/3)
    end

    @desc "Get a conversation by thread id"
    field :conversation, :conversation do
      arg(:mailbox_id, non_null(:id))
      arg(:thread_id, non_null(:id))
      resolve(&Resolvers.conversation/3)
    end

    @desc "Get sanitized message body content"
    field :message_body, :message_body do
      arg(:mailbox_id, non_null(:id))
      arg(:message_id, non_null(:id))
      resolve(&Resolvers.message_body/3)
    end
  end
end

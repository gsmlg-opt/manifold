defmodule ManifoldAPI.GraphQL.Types do
  @moduledoc false

  use Absinthe.Schema.Notation

  object :health do
    field(:status, non_null(:string))
    field(:service, non_null(:string))
  end

  object :domain do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:normalized_domain, non_null(:string))
    field(:active, non_null(:boolean))
  end

  object :mailbox do
    field(:id, non_null(:id))
    field(:local_part, non_null(:string))
    field(:display_name, :string)
    field(:active, non_null(:boolean))
    field(:plus_addressing_enabled, non_null(:boolean))
    field(:domain_id, non_null(:id))
    field(:domain, :domain)
    field(:address, :string)
  end

  object :folder do
    field(:id, non_null(:id))
    field(:kind, non_null(:string))
    field(:name, non_null(:string))
    field(:total_count, non_null(:integer))
    field(:unread_count, non_null(:integer))
  end

  object :conversation_summary do
    field(:thread_id, non_null(:id))
    field(:subject, :string)
    field(:sender_name, :string)
    field(:sender_address, :string)
    field(:preview, :string)
    field(:last_message_at, :string)
    field(:message_count, non_null(:integer))
    field(:unread, non_null(:boolean))
    field(:starred, non_null(:boolean))
    field(:attachment_count, non_null(:integer))
    field(:entry_ids, non_null(list_of(non_null(:id))))
  end

  object :conversation_page do
    field(:items, non_null(list_of(non_null(:conversation_summary))))
    field(:next_cursor, :string)
  end

  object :attachment do
    field(:id, non_null(:id))
    field(:filename, non_null(:string))
    field(:media_type, :string)
    field(:disposition, :string)
    field(:size, :integer)
    field(:content_id, :string)
    field(:url, non_null(:string))
  end

  object :message do
    field(:id, non_null(:id))
    field(:entry_id, non_null(:id))
    field(:subject, :string)
    field(:sender_name, :string)
    field(:sender_address, :string)
    field(:sent_at, :string)
    field(:received_at, :string)
    field(:text_body, :string)
    field(:has_html, non_null(:boolean))
    field(:read, non_null(:boolean))
    field(:starred, non_null(:boolean))
    field(:attachments, non_null(list_of(non_null(:attachment))))
  end

  object :conversation do
    field(:thread_id, non_null(:id))
    field(:subject, :string)
    field(:messages, non_null(list_of(non_null(:message))))
  end

  object :message_body do
    field(:text_body, :string)
    field(:html_body, :string)
    field(:has_html, non_null(:boolean))
  end
end

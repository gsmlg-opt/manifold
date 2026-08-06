defmodule ManifoldAPI.JSON do
  @moduledoc """
  Shared serialization from Accounts/Mail view structs to JSON-safe maps.
  """

  alias Manifold.Accounts.Schema.Account
  alias Manifold.Mail.View

  @spec mailbox(Account.t()) :: map()
  def mailbox(%Account{} = account) do
    domain = account.domain

    %{
      id: account.id,
      local_part: account.local_part,
      display_name: account.name,
      name: account.name,
      active: account.active,
      plus_addressing_enabled: account.plus_addressing_enabled,
      domain_id: account.domain_id,
      domain:
        if(domain,
          do: %{
            id: domain.id,
            name: domain.name,
            normalized_domain: domain.normalized_domain,
            active: domain.active
          },
          else: nil
        ),
      address:
        if(domain,
          do: account.local_part <> "@" <> domain.normalized_domain,
          else: nil
        )
    }
  end

  @spec folder(View.Folder.t()) :: map()
  def folder(%View.Folder{} = folder) do
    %{
      id: folder.id,
      kind: folder.kind,
      name: folder.name,
      total_count: folder.total_count,
      unread_count: folder.unread_count
    }
  end

  @spec conversation_page(View.ConversationPage.t()) :: map()
  def conversation_page(%View.ConversationPage{} = page) do
    %{
      items: Enum.map(page.items, &conversation_summary/1),
      next_cursor: page.next_cursor
    }
  end

  @spec conversation_summary(View.ConversationSummary.t()) :: map()
  def conversation_summary(%View.ConversationSummary{} = summary) do
    %{
      thread_id: summary.thread_id,
      subject: summary.subject,
      sender_name: summary.sender_name,
      sender_address: summary.sender_address,
      preview: summary.preview,
      last_message_at: datetime(summary.last_message_at),
      message_count: summary.message_count,
      unread: summary.unread,
      starred: summary.starred,
      attachment_count: summary.attachment_count,
      entry_ids: summary.entry_ids
    }
  end

  @spec conversation(View.Conversation.t(), Ecto.UUID.t()) :: map()
  def conversation(%View.Conversation{} = conversation, mailbox_id) do
    %{
      thread_id: conversation.thread_id,
      subject: conversation.subject,
      messages: Enum.map(conversation.messages, &message(&1, mailbox_id))
    }
  end

  @spec message(View.Message.t(), Ecto.UUID.t()) :: map()
  def message(%View.Message{} = message, mailbox_id) do
    %{
      id: message.id,
      entry_id: message.entry_id,
      subject: message.subject,
      sender_name: message.sender_name,
      sender_address: message.sender_address,
      sent_at: datetime(message.sent_at),
      received_at: datetime(message.received_at),
      text_body: message.text_body,
      has_html: message.has_html,
      read: message.read,
      starred: message.starred,
      attachments: Enum.map(message.attachments, &attachment(&1, mailbox_id))
    }
  end

  @spec attachment(View.Attachment.t(), Ecto.UUID.t()) :: map()
  def attachment(%View.Attachment{} = attachment, mailbox_id) do
    %{
      id: attachment.id,
      filename: attachment.filename,
      media_type: attachment.media_type,
      disposition: attachment.disposition,
      size: attachment.size,
      content_id: attachment.content_id,
      url: attachment_url(mailbox_id, attachment.id)
    }
  end

  @spec message_body(map()) :: map()
  def message_body(%{text_body: text_body, html_body: html_body, has_html: has_html}) do
    %{
      text_body: text_body,
      html_body: html_body,
      has_html: has_html
    }
  end

  @spec health() :: map()
  def health do
    %{status: "ok", service: "manifold_api"}
  end

  @spec attachment_url(Ecto.UUID.t(), Ecto.UUID.t()) :: String.t()
  def attachment_url(mailbox_id, attachment_id) do
    "/api/v1/mailboxes/#{mailbox_id}/attachments/#{attachment_id}"
  end

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(nil), do: nil
end

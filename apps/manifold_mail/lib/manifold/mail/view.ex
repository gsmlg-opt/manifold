defmodule Manifold.Mail.View.Folder do
  @moduledoc false
  @enforce_keys [:id, :kind, :name, :total_count, :unread_count]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          kind: String.t(),
          name: String.t(),
          total_count: non_neg_integer(),
          unread_count: non_neg_integer()
        }
end

defmodule Manifold.Mail.View.ConversationSummary do
  @moduledoc false
  @enforce_keys [
    :thread_id,
    :subject,
    :sender_name,
    :sender_address,
    :preview,
    :last_message_at,
    :message_count,
    :unread,
    :starred,
    :attachment_count,
    :entry_ids
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
end

defmodule Manifold.Mail.View.ConversationPage do
  @moduledoc false
  @enforce_keys [:items]
  defstruct [:next_cursor | @enforce_keys]

  @type t :: %__MODULE__{
          items: [Manifold.Mail.View.ConversationSummary.t()],
          next_cursor: String.t() | nil
        }
end

defmodule Manifold.Mail.View.Attachment do
  @moduledoc false
  @enforce_keys [:id, :filename, :media_type, :disposition, :size, :content_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
end

defmodule Manifold.Mail.View.Message do
  @moduledoc false
  @enforce_keys [
    :id,
    :entry_id,
    :subject,
    :sender_name,
    :sender_address,
    :sent_at,
    :text_body,
    :has_html,
    :read,
    :starred,
    :attachments
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
end

defmodule Manifold.Mail.View.Conversation do
  @moduledoc false
  @enforce_keys [:thread_id, :subject, :messages]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
end

defmodule Manifold.Mail.View.AttachmentDownload do
  @moduledoc false
  @enforce_keys [:filename, :media_type, :size, :io]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
end

defmodule Manifold.Mail.View.ReplySource do
  @moduledoc false
  @enforce_keys [
    :message_id,
    :rfc_message_id,
    :references,
    :subject,
    :sender,
    :reply_to,
    :to,
    :cc,
    :sent_at,
    :text_body
  ]
  defstruct @enforce_keys

  @type address :: %{display_name: String.t() | nil, address: String.t()}
  @type t :: %__MODULE__{
          message_id: Ecto.UUID.t(),
          rfc_message_id: String.t() | nil,
          references: [String.t()],
          subject: String.t(),
          sender: address(),
          reply_to: [address()],
          to: [address()],
          cc: [address()],
          sent_at: DateTime.t(),
          text_body: String.t() | nil
        }
end

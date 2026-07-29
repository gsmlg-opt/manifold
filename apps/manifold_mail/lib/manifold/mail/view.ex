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

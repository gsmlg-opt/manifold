defmodule Manifold.Mail.ParsedMessage do
  @moduledoc """
  Infrastructure-independent normalized output from the MIME parser boundary.
  """

  alias Manifold.Mail.ParsedMessage.Attachment

  @type address :: %{name: String.t() | nil, address: String.t()}
  @type header :: %{
          position: non_neg_integer(),
          original_name: String.t(),
          normalized_name: String.t(),
          value: String.t()
        }

  @type t :: %__MODULE__{
          subject: String.t() | nil,
          rfc_message_id: String.t() | nil,
          in_reply_to: String.t() | nil,
          references: [String.t()],
          sent_at: DateTime.t() | nil,
          from: [address()],
          sender: [address()],
          reply_to: [address()],
          to: [address()],
          cc: [address()],
          bcc: [address()],
          headers: [header()],
          text_body: String.t() | nil,
          html_body: String.t() | nil,
          attachments: [Attachment.t()]
        }

  defstruct subject: nil,
            rfc_message_id: nil,
            in_reply_to: nil,
            references: [],
            sent_at: nil,
            from: [],
            sender: [],
            reply_to: [],
            to: [],
            cc: [],
            bcc: [],
            headers: [],
            text_body: nil,
            html_body: nil,
            attachments: []
end

defmodule Manifold.Mail.ParsedMessage.Attachment do
  @moduledoc false

  @type t :: %__MODULE__{
          part_path: String.t(),
          content_id: String.t() | nil,
          filename: String.t() | nil,
          media_type: String.t(),
          disposition: String.t(),
          bytes: binary(),
          size: non_neg_integer(),
          sha256: String.t()
        }

  @enforce_keys [:part_path, :media_type, :disposition, :bytes, :size, :sha256]
  defstruct [
    :part_path,
    :content_id,
    :filename,
    :media_type,
    :disposition,
    :bytes,
    :size,
    :sha256
  ]
end

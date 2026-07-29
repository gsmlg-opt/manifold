defmodule Manifold.Outbound.View.Recipient do
  @moduledoc false

  @enforce_keys [:kind, :position, :address, :canonical_address, :delivery_state]
  defstruct [:display_name, :last_event_at, :status_detail | @enforce_keys]

  @type t :: %__MODULE__{
          kind: String.t(),
          position: non_neg_integer(),
          display_name: String.t() | nil,
          address: String.t(),
          canonical_address: String.t(),
          delivery_state: String.t(),
          last_event_at: DateTime.t() | nil,
          status_detail: String.t() | nil
        }
end

defmodule Manifold.Outbound.View.Draft do
  @moduledoc false

  @enforce_keys [
    :id,
    :composition_kind,
    :sender_address,
    :subject,
    :text_body,
    :recipients,
    :lock_version,
    :updated_at
  ]
  defstruct [:source_message_id, :in_reply_to, references: []] ++ @enforce_keys

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          composition_kind: String.t(),
          source_message_id: Ecto.UUID.t() | nil,
          sender_address: String.t(),
          subject: String.t() | nil,
          text_body: String.t() | nil,
          in_reply_to: String.t() | nil,
          references: [String.t()],
          recipients: [Manifold.Outbound.View.Recipient.t()],
          lock_version: pos_integer(),
          updated_at: DateTime.t()
        }
end

defmodule Manifold.Outbound.View.DraftSummary do
  @moduledoc false

  @enforce_keys [:id, :subject, :preview, :recipient_count, :updated_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          subject: String.t(),
          preview: String.t(),
          recipient_count: non_neg_integer(),
          updated_at: DateTime.t()
        }
end

defmodule Manifold.Outbound.View.SentSummary do
  @moduledoc false

  @enforce_keys [:id, :subject, :state, :recipients, :queued_at, :updated_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          subject: String.t(),
          state: String.t(),
          recipients: [String.t()],
          queued_at: DateTime.t() | nil,
          updated_at: DateTime.t()
        }
end

defmodule Manifold.Outbound.View.Submission do
  @moduledoc false

  @enforce_keys [:provider, :state, :attempt_count]
  defstruct [
    :provider_message_id,
    :accepted_at,
    :last_http_status,
    :last_error_code,
    :last_error_message
    | @enforce_keys
  ]

  @type t :: %__MODULE__{}
end

defmodule Manifold.Outbound.View.Event do
  @moduledoc false

  @enforce_keys [:event_type, :metadata, :occurred_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}
end

defmodule Manifold.Outbound.View.SentDetail do
  @moduledoc false

  @enforce_keys [
    :id,
    :state,
    :sender_address,
    :subject,
    :text_body,
    :recipients,
    :submission,
    :events,
    :queued_at,
    :updated_at
  ]
  defstruct [
    :accepted_at,
    :last_error_class,
    :last_error_code,
    :last_error_message | @enforce_keys
  ]

  @type t :: %__MODULE__{}
end

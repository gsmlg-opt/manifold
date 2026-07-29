defmodule Manifold.Outbound.Provider do
  @moduledoc """
  Managed outbound provider boundary.
  """

  alias Manifold.Outbound.Provider.{Envelope, Error, Event, Submission}

  @callback submit(keyword(), Envelope.t()) :: {:ok, Submission.t()} | {:error, Error.t()}
  @callback verify_webhook(keyword(), map(), binary(), Keyword.t()) ::
              {:ok, Event.t()} | {:error, Error.t()}

  @optional_callbacks verify_webhook: 4
end

defmodule Manifold.Outbound.Provider.Event do
  @moduledoc false

  @enforce_keys [
    :provider_event_id,
    :provider_message_id,
    :event_type,
    :normalized_state,
    :recipient_addresses,
    :occurred_at,
    :metadata
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          provider_event_id: String.t(),
          provider_message_id: String.t(),
          event_type: String.t(),
          normalized_state: String.t(),
          recipient_addresses: [String.t()],
          occurred_at: DateTime.t(),
          metadata: map()
        }
end

defmodule Manifold.Outbound.Provider.Envelope do
  @moduledoc false

  @enforce_keys [:from, :to, :cc, :bcc, :subject, :text, :idempotency_key]
  defstruct [:in_reply_to, references: []] ++ @enforce_keys

  @type t :: %__MODULE__{
          from: String.t(),
          to: [String.t()],
          cc: [String.t()],
          bcc: [String.t()],
          subject: String.t(),
          text: String.t(),
          in_reply_to: String.t() | nil,
          references: [String.t()],
          idempotency_key: String.t()
        }
end

defmodule Manifold.Outbound.Provider.Submission do
  @moduledoc false

  @enforce_keys [:provider_message_id, :metadata]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          provider_message_id: String.t(),
          metadata: map()
        }
end

defmodule Manifold.Outbound.Provider.Error do
  @moduledoc false

  @enforce_keys [:class, :code, :message]
  defstruct [:http_status, :retry_after | @enforce_keys]

  @type t :: %__MODULE__{
          class: :transient | :permanent,
          code: String.t(),
          message: String.t(),
          http_status: non_neg_integer() | nil,
          retry_after: non_neg_integer() | nil
        }
end

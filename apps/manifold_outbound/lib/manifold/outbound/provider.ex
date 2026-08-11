defmodule Manifold.Outbound.Provider do
  @moduledoc """
  Managed outbound provider boundary.
  """

  alias Manifold.Outbound.Provider.{Error, Event, Request, Submission}

  @callback submit(keyword(), Request.t()) :: {:ok, Submission.t()} | {:error, Error.t()}
  @callback verify_webhook(keyword(), map(), binary(), Keyword.t()) ::
              {:ok, Event.t()} | {:error, Error.t()}

  @optional_callbacks verify_webhook: 4

  @spec adapter(String.t()) :: {:ok, module()} | :error
  def adapter("gmail"), do: {:ok, Manifold.Outbound.Provider.Gmail}
  def adapter("smtp"), do: {:ok, Manifold.Outbound.Provider.SMTP}
  def adapter("resend"), do: {:ok, Manifold.Outbound.Provider.Resend}
  def adapter(_provider), do: :error
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
  defstruct [:message_id, :queued_at, :in_reply_to, references: []] ++ @enforce_keys

  @type t :: %__MODULE__{
          from: String.t(),
          to: [String.t()],
          cc: [String.t()],
          bcc: [String.t()],
          subject: String.t(),
          text: String.t(),
          message_id: String.t() | nil,
          queued_at: DateTime.t() | nil,
          in_reply_to: String.t() | nil,
          references: [String.t()],
          idempotency_key: String.t()
        }
end

defmodule Manifold.Outbound.Provider.Request do
  @moduledoc false

  @enforce_keys [:provider, :send_method_id, :envelope, :raw_message, :request_sha256]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          provider: String.t(),
          send_method_id: Ecto.UUID.t() | nil,
          envelope: Manifold.Outbound.Provider.Envelope.t(),
          raw_message: binary(),
          request_sha256: String.t()
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
          class: :transient | :permanent | :uncertain,
          code: String.t(),
          message: String.t(),
          http_status: non_neg_integer() | nil,
          retry_after: non_neg_integer() | nil
        }
end

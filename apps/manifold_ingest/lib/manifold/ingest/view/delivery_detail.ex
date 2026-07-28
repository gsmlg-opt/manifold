defmodule Manifold.Ingest.View.DeliveryDetail do
  @moduledoc """
  Public delivery detail projection for Phoenix and API consumers.
  """

  @type t :: %__MODULE__{
          delivery: struct(),
          recipients: [struct()],
          mailboxes: [map()],
          events: [struct()]
        }

  defstruct [:delivery, recipients: [], mailboxes: [], events: []]
end

defmodule Manifold.Connectors.Schema.CalendarOAuthTransaction do
  @moduledoc false
  use Manifold.Connectors.Schema

  schema "calendar_oauth_transactions" do
    field :state_digest, :binary, redact: true
    field :verifier_ciphertext, :binary, redact: true
    field :redirect_uri, :string
    field :setting_id, :binary_id
    field :setting_version, :integer
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

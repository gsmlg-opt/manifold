defmodule Manifold.Outbound.Schema.ProviderSubmission do
  @moduledoc false

  use Manifold.Outbound.Schema
  import Ecto.Changeset

  schema "provider_submissions" do
    field(:outbound_message_id, :binary_id)
    field(:provider, :string)
    field(:idempotency_key, :string)
    field(:request_sha256, :string)
    field(:state, :string, default: "pending")
    field(:attempt_count, :integer, default: 0)
    field(:provider_message_id, :string)
    field(:provider_rfc_message_id, :string)
    field(:first_attempt_at, :utc_datetime_usec)
    field(:last_attempt_at, :utc_datetime_usec)
    field(:accepted_at, :utc_datetime_usec)
    field(:idempotency_expires_at, :utc_datetime_usec)
    field(:last_http_status, :integer)
    field(:last_error_code, :string)
    field(:last_error_message, :string)
    field(:provider_metadata, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [
      :outbound_message_id,
      :provider,
      :idempotency_key,
      :request_sha256,
      :state,
      :attempt_count,
      :provider_message_id,
      :provider_rfc_message_id,
      :first_attempt_at,
      :last_attempt_at,
      :accepted_at,
      :idempotency_expires_at,
      :last_http_status,
      :last_error_code,
      :last_error_message,
      :provider_metadata
    ])
    |> validate_required([
      :outbound_message_id,
      :provider,
      :idempotency_key,
      :request_sha256,
      :state,
      :attempt_count,
      :idempotency_expires_at
    ])
    |> validate_inclusion(:state, ~w(pending submitting accepted failed uncertain))
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_format(:request_sha256, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:outbound_message_id)
    |> unique_constraint(:outbound_message_id)
    |> unique_constraint([:provider, :idempotency_key])
    |> unique_constraint([:provider, :provider_message_id])
    |> check_constraint(:attempt_count, name: :provider_submissions_attempt_nonnegative)
    |> check_constraint(:state, name: :provider_submissions_state_valid)
  end
end

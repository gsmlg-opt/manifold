defmodule Manifold.Mail.Schema.Message do
  @moduledoc false

  use Manifold.Mail.Schema
  import Ecto.Changeset

  @parse_states ~w(pending parsed fallback failed)

  schema "messages" do
    field(:inbound_delivery_id, :binary_id)
    field(:rfc_message_id, :string)
    field(:in_reply_to, :string)
    field(:references, {:array, :string}, default: [])
    field(:subject, :string)
    field(:sender_name, :string)
    field(:sender_address, :string)
    field(:sent_at, :utc_datetime_usec)
    field(:received_at, :utc_datetime_usec)
    field(:text_body, :string)
    field(:sanitized_html, :string)
    field(:parser_version, :integer)
    field(:sanitizer_version, :integer)
    field(:parse_state, :string, default: "pending")
    field(:parse_error, :string)
    field(:search_document, :string, load_in_query: false)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :inbound_delivery_id,
      :rfc_message_id,
      :in_reply_to,
      :references,
      :subject,
      :sender_name,
      :sender_address,
      :sent_at,
      :received_at,
      :text_body,
      :sanitized_html,
      :parser_version,
      :sanitizer_version,
      :parse_state,
      :parse_error
    ])
    |> validate_required([:inbound_delivery_id, :parser_version, :parse_state])
    |> validate_inclusion(:parse_state, @parse_states)
    |> validate_number(:parser_version, greater_than: 0)
    |> validate_number(:sanitizer_version, greater_than: 0)
    |> validate_references()
    |> unique_constraint(:inbound_delivery_id,
      name: :messages_inbound_delivery_id_index
    )
    |> foreign_key_constraint(:inbound_delivery_id,
      name: :messages_inbound_delivery_id_fkey
    )
    |> check_constraint(:parser_version,
      name: :messages_parser_version_positive
    )
    |> check_constraint(:sanitizer_version,
      name: :messages_sanitizer_version_positive
    )
    |> check_constraint(:parse_state, name: :messages_parse_state_valid)
  end

  defp validate_references(changeset) do
    validate_change(changeset, :references, fn :references, references ->
      if Enum.all?(references, &(is_binary(&1) and byte_size(&1) <= 998)) do
        []
      else
        [references: "must contain RFC message identifiers no longer than 998 bytes"]
      end
    end)
  end
end

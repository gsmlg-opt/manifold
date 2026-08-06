defmodule Manifold.Connectors.Schema.SmtpSettings do
  @moduledoc false

  use Manifold.Connectors.Schema
  import Ecto.Changeset

  # `ssl` and `tls` are both implicit TLS (handshake on connect).
  # Prefer `tls` for new settings; `ssl` is kept for backward compatibility.
  @tls_modes ~w(ssl tls starttls)

  schema "connector_smtp_settings" do
    field(:send_method_id, :binary_id)
    field(:host, :string)
    field(:port, :integer)
    field(:tls_mode, :string)
    field(:username, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:send_method_id, :host, :port, :tls_mode, :username])
    |> validate_required([:send_method_id, :host, :port, :tls_mode, :username])
    |> validate_inclusion(:tls_mode, @tls_modes)
    |> validate_number(:port, greater_than: 0, less_than_or_equal_to: 65_535)
    |> validate_length(:host, min: 1, max: 253)
    |> validate_length(:username, min: 1, max: 320)
    |> unique_constraint(:send_method_id)
  end
end

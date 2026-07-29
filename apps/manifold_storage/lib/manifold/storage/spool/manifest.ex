defmodule Manifold.Storage.Spool.Manifest do
  @moduledoc """
  Versioned JSON manifest written beside each raw transport message in the spool.
  """

  @version 2

  @type route :: map()
  @type t :: %__MODULE__{
          version: pos_integer(),
          ingest_id: String.t(),
          received_at: DateTime.t(),
          source_kind: String.t(),
          external_provider: String.t() | nil,
          external_source_id: String.t() | nil,
          external_message_id: String.t() | nil,
          storage_domain_id: String.t() | nil,
          target_mailbox_id: String.t() | nil,
          peer_ip: String.t() | nil,
          helo: String.t() | nil,
          envelope_from: String.t() | nil,
          original_recipients: [String.t()],
          routes: [route()],
          raw_size: non_neg_integer(),
          raw_sha256: String.t()
        }

  @derive Jason.Encoder
  defstruct [
    :ingest_id,
    :received_at,
    :source_kind,
    :external_provider,
    :external_source_id,
    :external_message_id,
    :storage_domain_id,
    :target_mailbox_id,
    :peer_ip,
    :helo,
    :envelope_from,
    :raw_size,
    :raw_sha256,
    version: @version,
    original_recipients: [],
    routes: []
  ]

  @spec build(map(), binary()) :: t()
  def build(attrs, raw) do
    build_from_stat(attrs, byte_size(raw), sha256(raw))
  end

  @spec build_from_stat(map(), non_neg_integer(), String.t()) :: t()
  def build_from_stat(attrs, raw_size, raw_sha256) do
    %__MODULE__{
      ingest_id: Map.fetch!(attrs, :ingest_id),
      received_at: Map.fetch!(attrs, :received_at),
      source_kind: Map.get(attrs, :source_kind, "smtp"),
      external_provider: Map.get(attrs, :external_provider),
      external_source_id: Map.get(attrs, :external_source_id),
      external_message_id: Map.get(attrs, :external_message_id),
      storage_domain_id: Map.get(attrs, :storage_domain_id),
      target_mailbox_id: Map.get(attrs, :target_mailbox_id),
      peer_ip: Map.get(attrs, :peer_ip),
      helo: Map.get(attrs, :helo),
      envelope_from: Map.get(attrs, :envelope_from),
      original_recipients: Map.get(attrs, :original_recipients, []),
      routes: attrs |> Map.get(:routes, []) |> Enum.map(&route_to_map/1),
      raw_size: raw_size,
      raw_sha256: raw_sha256
    }
  end

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json),
         {:ok, received_at, _offset} <- DateTime.from_iso8601(map["received_at"]) do
      {:ok,
       %__MODULE__{
         version: map["version"],
         ingest_id: map["ingest_id"],
         received_at: received_at,
         source_kind: map["source_kind"] || "smtp",
         external_provider: map["external_provider"],
         external_source_id: map["external_source_id"],
         external_message_id: map["external_message_id"],
         storage_domain_id: map["storage_domain_id"],
         target_mailbox_id: map["target_mailbox_id"],
         peer_ip: map["peer_ip"],
         helo: map["helo"],
         envelope_from: map["envelope_from"],
         original_recipients: map["original_recipients"] || [],
         routes: map["routes"] || [],
         raw_size: map["raw_size"],
         raw_sha256: map["raw_sha256"]
       }}
    end
  end

  @spec sha256(binary()) :: String.t()
  def sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  @spec sha256_file(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def sha256_file(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        hash_file(file, :crypto.hash_init(:sha256))
      after
        File.close(file)
      end
    end
  end

  defp hash_file(file, context) do
    case IO.binread(file, 64 * 1024) do
      data when is_binary(data) ->
        hash_file(file, :crypto.hash_update(context, data))

      :eof ->
        {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_to_map(%_{} = struct), do: struct |> Map.from_struct() |> stringify_keys()
  defp route_to_map(map) when is_map(map), do: stringify_keys(map)

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), value}
    end)
  end
end

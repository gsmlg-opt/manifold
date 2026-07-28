defmodule Manifold.Storage.Spool.Manifest do
  @moduledoc """
  Versioned JSON manifest written beside each raw SMTP message in the spool.
  """

  @version 1

  @type route :: map()
  @type t :: %__MODULE__{
          version: pos_integer(),
          ingest_id: String.t(),
          received_at: DateTime.t(),
          peer_ip: String.t(),
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
    %__MODULE__{
      ingest_id: Map.fetch!(attrs, :ingest_id),
      received_at: Map.fetch!(attrs, :received_at),
      peer_ip: Map.fetch!(attrs, :peer_ip),
      helo: Map.get(attrs, :helo),
      envelope_from: Map.get(attrs, :envelope_from),
      original_recipients: Map.get(attrs, :original_recipients, []),
      routes: attrs |> Map.get(:routes, []) |> Enum.map(&route_to_map/1),
      raw_size: byte_size(raw),
      raw_sha256: sha256(raw)
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
